;;;; lisp/supervisor.lisp
;;;; 旁路督导子 Agent (Supervisor SubAgent) 与死循环程序化决策回退引擎
;;;;
;;;; 设计目标：
;;;;   1. 取代「一刀切 15 秒必杀」的粗暴超时，避免误杀合法的耗时任务；
;;;;   2. 通过「进展心跳 + SBCL 实时非侵入式调用栈采样 (list-backtrace)」感知工作线程真实状态；
;;;;   3. 当检测到无进展停滞或跨轮次鬼打墙时，由督导子 Agent（程序化规则 + 轻量 LLM SubAgent）
;;;;      在三种动作间做程序化决策：
;;;;        - :EXTEND        — 任务仍在正常推进，顺延等待窗口，不误杀
;;;;        - :ABORT-TOOL    — 单次工具调用陷入死循环，精准中断并附上 SBCL 调用栈诊断
;;;;        - :ROLLBACK-CODE — 热重载的新代码引发死循环，自动回滚磁盘与内存代码并中断当前工具

(in-package :cl-user)

(declaim (special *lisp-unverified-backups*
                  *http-connect-timeout*
                  *http-max-time*))

;;; ── 配置与全局状态 ───────────────────────────────────

(defparameter *supervisor-enabled* t
  "是否启用旁路督导子 Agent 监听死循环。")

(defparameter *supervisor-subagent-enabled* t
  "遇到疑似死循环时，是否调用轻量级 LLM SubAgent 进行深度裁决（失败或关闭时自动回退到纯程序化规则）。")

(defparameter *supervisor-soft-stall-seconds* 6.0
  "工作线程连续多少秒无进展心跳后，开始介入并进行 SBCL 调用栈采样。")

(defparameter *supervisor-sample-interval* 2.0
  "进入疑似停滞后，每次调用栈采样的间隔秒数。")

(defparameter *supervisor-sample-count* 3
  "每次督导裁决前收集的连续调用栈采样次数（例如 6s + 3*2s = 12s 无进展触发裁决）。")

(defparameter *supervisor-max-extensions* 4
  "单次工具调用最多允许被督导子 Agent 顺延 (:EXTEND) 的次数，防止无限顺延。")

(defvar *worker-progress-ticks* 0
  "工作线程进展心跳计数器（文件读写、stdout 输出等都会递增它）。")

(defvar *active-eval-stdout-stream* nil
  "当前 eval_lisp 正在使用的 stdout string-output-stream，供督导线程实时检测输出增长。")

(defvar *supervisor-turn-history* nil
  "当前 run-agent 会话中最近几轮的工具调用指纹历史，用于检测跨轮次死循环。")

(defvar *supervisor-stall-count* 0
  "当前 run-agent 会话中累计触发死循环熔断的次数。")

(defun reset-supervisor-session ()
  "在每次 run-agent 开始时重置督导会话状态。"
  (setf *worker-progress-ticks* 0
        *supervisor-turn-history* nil
        *supervisor-stall-count* 0)
  nil)

(defun note-worker-progress (&optional (delta 1))
  "工作线程主动汇报一次进展心跳。"
  (incf *worker-progress-ticks* delta))

(defun current-worker-progress-signature ()
  "读取当前工作线程的综合进展签名（心跳计数 + eval_lisp 实时输出长度）。"
  (let ((out-len (ignore-errors
                   (let ((s *active-eval-stdout-stream*))
                     (if (and s (streamp s))
                         (or (file-position s) 0)
                         0)))))
    (+ (* *worker-progress-ticks* 1000000) (or out-len 0))))

;;; ── SBCL 实时非侵入式调用栈采样 ─────────────────────

(defun internal-noise-frame-p (frame-str)
  "过滤掉 SBCL 线程调度与信号中断本身的底层噪声栈帧。"
  (or (search "WITH-DEFERRABLE-SIGNALS-UNBLOCKED" frame-str :test #'char-equal)
      (search "WITHOUT-INTERRUPTS-BODY" frame-str :test #'char-equal)
      (search "SB-THREAD::RUN" frame-str :test #'char-equal)
      (search "SAMPLE-WORKER-BACKTRACE" frame-str :test #'char-equal)
      (search "LIST-BACKTRACE" frame-str :test #'char-equal)))

#+sb-thread
(defun sample-worker-backtrace (thread &key (max-frames 8))
  "对正在运行的工作线程执行一次非破坏性调用栈采样（不终止线程）。
返回栈帧字符串列表（从栈顶到栈底）。"
  (when (and thread (ignore-errors (sb-thread:thread-alive-p thread)))
    (let ((captured nil)
          (done nil))
      (ignore-errors
        (sb-thread:interrupt-thread
         thread
         (lambda ()
           (ignore-errors
             (let ((raw (sb-debug:list-backtrace :count (+ max-frames 8))))
               (setf captured
                     (loop for f in raw
                           for head = (prin1-to-string (if (consp f) (car f) f))
                           unless (internal-noise-frame-p head)
                           collect head
                           into clean
                           when (>= (length clean) max-frames)
                           do (return clean)
                           finally (return clean)))))
           (setf done t))))
      (dotimes (i 15)
        (declare (ignore i))
        (when done (return))
        (sleep 0.005))
      captured)))

#-sb-thread
(defun sample-worker-backtrace (thread &key (max-frames 8))
  (declare (ignore thread max-frames))
  nil)

(defun format-backtrace-samples (samples)
  "将多次采样的调用栈格式化为紧凑文本。"
  (if (null samples)
      "(未能采集到调用栈)"
      (with-output-to-string (out)
        (loop for s in samples
              for idx from 1
              do (format out "  采样#~D: ~{~A~^ -> ~}~%"
                         idx (or s '("(空)")))))))

;;; ── 程序化规则判定 + SubAgent 深度裁决 ──────────────

(defun stack-contains-any-p (frames keywords)
  "检查栈帧列表中是否出现任一关键字。"
  (some (lambda (f)
          (some (lambda (kw) (search kw f :test #'char-equal)) keywords))
        frames))

(defun stacks-identical-p (samples)
  "检查多次采样的栈顶核心帧是否完全相同（原地自旋/死锁特征）。"
  (and (>= (length samples) 2)
       (let ((first-stack (first samples)))
         (and first-stack
              (every (lambda (s) (equal s first-stack)) (rest samples))))))

(defun extract-json-object-substring (text)
  "从模型返回的文本中提取第一个 {...} JSON 子串。"
  (when (stringp text)
    (let ((start (position #\{ text))
          (end (position #\} text :from-end t)))
      (when (and start end (> end start))
        (subseq text start (1+ end))))))

(defun consult-supervisor-subagent (tool-name args-summary elapsed-sec samples unverified-files)
  "启动轻量级督导子 Agent (Supervisor SubAgent)，根据实时调用栈与上下文做出 JSON 决策。
返回 (values 决策关键字 原因说明)；若网络异常或超时则返回 (values nil nil) 交由程序化兜底。"
  (when (and *supervisor-subagent-enabled*
             (fboundp 'resolve-llm-config)
             (fboundp 'http-post-json))
    (handler-case
        (let* ((config (funcall 'resolve-llm-config :allow-empty-key t))
               (api-key (and config (llm-config-api-key config))))
          (when (and (stringp api-key) (plusp (length api-key)))
            (let* ((url (format nil "~A/v1/messages" (llm-config-base-url config)))
                   (headers (list "Content-Type: application/json"
                                  (format nil "x-api-key: ~A" api-key)
                                  "anthropic-version: 2023-06-01"))
                   (sys "你是 MyAgent 的旁路督导子 Agent (Supervisor Watchdog)。你的职责是分析主线程工作任务在运行期的实时 SBCL 调用栈采样，判断是否陷入死循环或阻塞，并输出严格的 JSON 决策。只允许输出一个 JSON 对象，格式为：{\"action\": \"extend\" | \"abort_tool\" | \"rollback_code\", \"reason\": \"简短中文原因\"}。
规则：
1. 若调用栈卡在控制台读取（如 READ-CONSOLE-LINE / %CONSOLE-FETCH-RECORDS / READ-LINE）或连续多次采样停留在同一循环且无输出进展，说明陷入死循环；
2. 若陷入死循环且『待验证的热重载文件』非空（说明刚改坏了核心代码），选择 \"rollback_code\"；
3. 若只是单次工具调用参数/测试代码写出了死循环（核心文件未改坏），选择 \"abort_tool\"；
4. 若调用栈显示正在做合理的耗时计算或外部程序调用，选择 \"extend\"。")
                   (prompt (format nil "工具名称: ~A~%参数摘要: ~A~%已无进展耗时: ~,1F 秒~%本会话历史卡死次数: ~D~%待验证的热重载文件: ~A~%连续 ~D 次 SBCL 实时调用栈采样:~%~A~%请给出 JSON 决策："
                                   tool-name
                                   args-summary
                                   elapsed-sec
                                   *supervisor-stall-count*
                                   (if unverified-files
                                       (format nil "~{~A~^, ~}" unverified-files)
                                       "无")
                                   (length samples)
                                   (format-backtrace-samples samples)))
                   (body (jobj "model" (llm-config-model config)
                               "max_tokens" 256
                               "system" sys
                               "messages" (list (jobj "role" "user" "content" prompt))))
                   ;; 督导请求自身使用短超时（8秒），绝不拖慢主流程
                   (*http-connect-timeout* "5")
                   (*http-max-time* "8")
                   (resp (funcall 'http-post-json url headers body))
                   (text (and (hash-table-p resp)
                              (fboundp 'collect-answer-text)
                              (funcall 'collect-answer-text (jget resp "content"))))
                   (json-str (extract-json-object-substring text))
                   (parsed (and json-str (ignore-errors (json-decode json-str))))
                   (action-str (and (hash-table-p parsed) (jget parsed "action")))
                   (reason-str (and (hash-table-p parsed) (jget parsed "reason"))))
              (cond
                ((string-equal action-str "extend")
                 (values :extend (or reason-str "督导子 Agent 判定任务仍在推进")))
                ((string-equal action-str "rollback_code")
                 (values :rollback-code (or reason-str "督导子 Agent 判定热重载代码引起死循环，执行回退")))
                ((string-equal action-str "abort_tool")
                 (values :abort-tool (or reason-str "督导子 Agent 判定当前工具陷入死循环")))
                (t (values nil nil))))))
      (error () (values nil nil)))))

(defun current-unverified-file-list ()
  "返回当前尚未通过验证的热重载文件列表。"
  (when (and (boundp '*lisp-unverified-backups*)
             (hash-table-p *lisp-unverified-backups*))
    (loop for k being the hash-keys of *lisp-unverified-backups* collect k)))

(defun supervisor-decide-action (tool-name args-summary elapsed-sec samples extensions-used)
  "综合「程序化确定性特征」与「督导子 Agent (LLM)」做出最终决策。
返回 (values 决策关键字 (:extend | :abort-tool | :rollback-code) 诊断说明)。"
  (let* ((latest-stack (car (last samples)))
         (unverified (current-unverified-file-list))
         (has-unverified (and unverified t))
         (console-blocked-p
           (stack-contains-any-p latest-stack
                                 '("READ-CONSOLE-LINE" "%CONSOLE-FETCH-RECORDS"
                                   "CLI-READ-LINE" "CLI-READ-INPUT" "COLLECT-PASTED-INPUT")))
         (frozen-stack-p (stacks-identical-p samples)))
    (cond
      ;; 1. 确定性快速路径：工具内部误入控制台读取阻塞循环 → 毫秒级立即中断/回退
      (console-blocked-p
       (if (and has-unverified (>= *supervisor-stall-count* 1))
           (values :rollback-code
                   (format nil "程序化督导检测到工具 ~A 阻塞在控制台输入循环 (~{~A~^ -> ~})，且存在未验证的代码修改"
                           tool-name (subseq latest-stack 0 (min 4 (length latest-stack)))))
           (values :abort-tool
                   (format nil "程序化督导检测到工具 ~A 在非交互上下文中阻塞等待控制台输入 (~{~A~^ -> ~})"
                           tool-name (subseq latest-stack 0 (min 4 (length latest-stack)))))))

      ;; 2. 顺延次数已达上限 → 不再继续等待，直接根据是否有未验证代码决定中断或回滚
      ((>= extensions-used *supervisor-max-extensions*)
       (if has-unverified
           (values :rollback-code
                   (format nil "工具 ~A 已连续顺延 ~D 次（累计 ~,1F 秒无进展），自动回滚未验证代码"
                           tool-name extensions-used elapsed-sec))
           (values :abort-tool
                   (format nil "工具 ~A 已连续顺延 ~D 次（累计 ~,1F 秒无进展，栈帧: ~{~A~^ -> ~}）"
                           tool-name extensions-used elapsed-sec
                           (subseq latest-stack 0 (min 4 (length latest-stack)))))))

      ;; 3. 调用栈在多次采样间明显变化（非原地死循环） → 程序化直接顺延窗口，避免误杀合法长任务
      ((and (not frozen-stack-p) (not (null latest-stack)) (< extensions-used 2))
       (values :extend
               (format nil "调用栈仍在推进 (~A)，未处于同一死循环帧"
                       (or (first latest-stack) "running"))))

      ;; 4. 疑似死循环（调用栈冻结或长期无进展）→ 请督导子 Agent (LLM) 结合调用栈做裁决
      (t
       (multiple-value-bind (sub-action sub-reason)
           (consult-supervisor-subagent tool-name args-summary elapsed-sec samples unverified)
         (cond
           (sub-action
            ;; 若子 Agent 要求 rollback_code 但当前其实没有未验证文件，则降级为 abort_tool
            (if (and (eq sub-action :rollback-code) (not has-unverified))
                (values :abort-tool sub-reason)
                (values sub-action sub-reason)))
           ;; 5. 子 Agent 不可用时的确定性兜底：栈完全冻结则中断（有未验证代码且多次卡死则回滚）
           (frozen-stack-p
            (if (and has-unverified (>= *supervisor-stall-count* 1))
                (values :rollback-code
                        (format nil "连续 ~D 次采样调用栈完全冻结在 (~{~A~^ -> ~})，自动回滚未验证修改"
                                (length samples) (subseq latest-stack 0 (min 4 (length latest-stack)))))
                (values :abort-tool
                        (format nil "连续 ~D 次采样调用栈完全冻结在 (~{~A~^ -> ~})，无任何输出进展"
                                (length samples) (subseq latest-stack 0 (min 4 (length latest-stack)))))))
           (t
            (values :extend "暂未发现确定性死锁特征，顺延观察窗口"))))))))

;;; ── 跨轮次行为死循环检测（防多轮原地鬼打墙） ─────────

(defun record-turn-tool-signature (tool-name args-line failed-or-stalled-p)
  "记录每一轮工具调用的签名，返回是否触发了「跨轮次重复死循环」（连续 3 次相同调用或连续 2 次卡死）。"
  (let ((sig (format nil "~A:~A" tool-name (subseq args-line 0 (min 80 (length args-line))))))
    (push (list :sig sig :bad failed-or-stalled-p) *supervisor-turn-history*)
    (when (> (length *supervisor-turn-history*) 8)
      (setf *supervisor-turn-history* (subseq *supervisor-turn-history* 0 8)))
    (let* ((top3 (subseq *supervisor-turn-history* 0 (min 3 (length *supervisor-turn-history*))))
           (same-3-p (and (= (length top3) 3)
                          (every (lambda (item) (string= (getf item :sig) sig)) top3))))
      same-3-p)))

(defun maybe-intervene-turn-loop (tool-name args-line)
  "当检测到跨轮次重复死循环时，生成督导干预提示（必要时自动回滚未验证代码）。"
  (let ((rolled nil))
    (when (and (fboundp 'unverified-lisp-backups-p)
               (funcall 'unverified-lisp-backups-p)
               (fboundp 'rollback-unverified-lisp-files))
      (setf rolled (funcall 'rollback-unverified-lisp-files
                            (format nil "跨轮次重复调用 ~A 陷入死循环" tool-name))))
    (format nil "<supervisor-intervention>~%## [督导子 Agent 强制干预] 检测到跨轮次死循环~%你已经连续 3 轮以几乎相同的参数调用工具 `~A` (`~A`)。~A~%请立即停止重复相同的调用方式！如果是自测代码卡住，请改用纯函数输入参数测试，不要在 eval_lisp 中直接调用会阻塞等待控制台的交互函数。~%</supervisor-intervention>"
            tool-name
            args-line
            (if rolled
                (format nil "~%督导器已程序化自动回滚了刚修改的 ~D 个未验证文件：~{~A~^, ~}。" (length rolled) rolled)
                ""))))
