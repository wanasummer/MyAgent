;;;; lisp/agent-loop.lisp
;;;; 核心 Agent 循环 (ReAct Loop) — Common Lisp 原生热迭代与 Prompt Cache 优化版

(in-package :cl-user)

(defparameter *max-turns* nil
  "单次对话最大 ReAct 推理轮数；nil 表示不设上限（默认）。设为整数则在该轮数后停止。")

(defparameter *max-empty-answer-retries* 1
  "模型返回「无文本内容」时，自动请求其补充回答的最大次数（只重试 1 次，节省轮数）。")

(defparameter *auto-reload-before-turn* nil
  "是否在每轮推理前自动扫描并热重载磁盘上被修改的 .lisp 文件。默认 nil：避免任务进行中因外部改动/自动回滚而被打断。需要时设 t，或用 reload_lisp 手动重载。")

(defparameter *system-prompt*
  "你是一个基于原生 Common Lisp (SBCL) 构建的本地文件管理与自我演化 Agent。
你可以使用提供的工具来操控本机文件系统，并利用 Lisp 的动态热重载与求值能力在对话中直接迭代自身的核心功能。

## Lisp 实时自我迭代机制（免重启）

你的全部核心代码运行在单个常驻 SBCL 进程镜像中，源码位于项目的 `lisp/` 目录下：
- `lisp/reload-engine.lisp` — 安全热重载引擎（快照 / 自动回滚 / 错误回传）
- `lisp/json.lisp`       — 纯 Common Lisp JSON 解析与序列化器
- `lisp/config.lisp`     — `.env` 与多提供商 LLM 配置解析
- `lisp/file-utils.lisp` — 文件与目录读写底层实现
- `lisp/llm-client.lisp` — Anthropic / OpenAI / ThirdParty 多提供商客户端
- `lisp/tools.lisp`      — 动态工具注册表 (`*tool-registry*`) 与工具实现
- `lisp/agent-loop.lisp` — 核心 ReAct Agent 循环 (`run-agent`)
- `lisp/cli.lisp`        — 控制台交互式 CLI REPL

当用户要求你新增功能、修改核心逻辑或新增工具时：
1. **持久化修改并自动热重载**：使用 `write_file` 修改 `lisp/*.lisp` 中的代码。`write_file` 写入 `.lisp` 文件后会自动调用 `(hot-reload-lisp-file ...)` 将新定义即时编译加载进当前内存镜像！
2. **内存即时求值 (`eval_lisp`)**：你也可以直接调用 `eval_lisp` 工具执行 `(defun ...)` 或 `(register-tool ...)`。新注册或修改的工具在**下一轮推理 (Turn) 中即可立即调用**，完全无需退出或执行 `npm run dev` / 构建脚本！
3. **失败自动回滚（重要）**：热重载失败**不会中断任务**。系统会自动把磁盘文件与内存定义回滚到「上一个可用版本」，并把编译错误返回给你（在 write_file 的返回值或 <system-reminder> 里）。看到「热重载失败」时，务必阅读错误、修复代码后重新写入；在重载成功前，不要假设改动已生效。

## 你的工作模式：ReAct (Reasoning + Acting)

1. **思考 (Thought)**：分析用户意图，判断是否需要查看目录/文件或执行 Lisp 热更新。
2. **行动 (Action)**：调用合适的工具（文件工具、`eval_lisp`、`reload_lisp`）。
3. **观察 (Observation)**：分析工具返回结果。
4. **回答 (Answer)**：信息足够或操作完成后，用中文给出清晰完整的最终答案（结论先行，不要使用 emoji）。

## 行为准则

- **先看后动**：操作文件前先用 `list_directory` 或 `read_file` 了解情况。
- **路径使用**：支持绝对路径、相对路径和 `~`（自动展开为用户主目录）。
- **安全第一**：执行 `delete_path` 前务必确认用户意图。
- **中文交流**：始终用清晰简洁的中文与用户沟通。
- **禁止 emoji**：回答、日志与生成的文件内容中一律不要使用 emoji 或装饰性符号；需要强调时改用 Markdown 加粗、列表，或纯文本标签 [OK] / [WARN] / [ERR]。
- **结论先行**：开头用一句中文结论概括结果（如「已完成：…」），再展开细节。
- **禁止空回答**：每轮结束若不再调用工具，必须输出非空的最终文本答案。"
  "静态系统提示词（保持前缀一致以命中 Anthropic Prompt Cache）。")

;;; ── 动态环境上下文 (<system-reminder>) ───────────────

(defun build-environment-context ()
  "构建动态环境上下文，注入到用户消息中以保护 System Prompt 缓存。"
  (let* ((home-dir (get-user-home-dir))
         (desktop-dir (format nil "~A/Desktop" home-dir))
         (project-dir (resolve-path "."))
         (today (current-date-string)))
    (format nil "<system-reminder>~%## 当前环境~%- 今天的日期：~A~%- 运行时：SBCL ~A (Common Lisp)~%- 你的工作目录（项目目录）：`~A`~%- 核心 Lisp 源码目录：`~A/lisp`~%- 用户主目录：`~A`~%- 用户桌面：`~A`~%- 已注册工具列表：~{~A~^, ~}~%</system-reminder>"
            today
            (lisp-implementation-version)
            project-dir
            project-dir
            home-dir
            desktop-dir
            *tool-names-order*)))

;;; ── 项目纲领 (Agents.md) 动态注入 ─────────────────────

(defparameter *agents-md-filename* "Agents.md"
  "项目纲领文件名：位于项目根目录，每轮 LLM 请求前读取并追加到 System Prompt 末尾。")

(defparameter *agents-md-max-chars* 20000
  "注入 Agents.md 的最大字符数，超出部分截断，避免挤占上下文预算。")

(defvar *agents-md-cache* nil
  "Agents.md 缓存：(:path 路径 :mtime 写入时间 :content 文本)。按 mtime 失效，改文件后下一轮自动生效。")

(defun agents-md-path ()
  "返回项目根目录下 Agents.md 的路径；解析失败时返回 nil。"
  (ignore-errors (resolve-path *agents-md-filename*)))

(defun load-agents-md (&optional force)
  "读取并缓存项目纲领 Agents.md 正文；文件不存在、读取失败或内容为空时返回 nil。
以 file-write-date 作为缓存键，因此编辑保存后下一轮请求即生效，无需重启或热重载。"
  (let ((path (agents-md-path)))
    (when (and path (probe-file path))
      (let ((mtime (ignore-errors (file-write-date path)))
            (cached *agents-md-cache*))
        (unless (and (not force)
                     cached
                     (equal (getf cached :path) path)
                     (eql (getf cached :mtime) mtime))
          (setf *agents-md-cache*
                (list :path path
                      :mtime mtime
                      :content (handler-case
                                   (uiop:read-file-string path :external-format :utf-8)
                                 (error () nil)))))
        (let ((text (getf *agents-md-cache* :content)))
          (when (stringp text)
            (setf text (string-trim '(#\Space #\Tab #\Newline #\Return) text))
            (cond
              ((zerop (length text)) nil)
              ((> (length text) *agents-md-max-chars*)
               (format nil "~A~%~%;; [Agents.md 超出 ~D 字符上限，已截断]"
                       (subseq text 0 *agents-md-max-chars*)
                       *agents-md-max-chars*))
              (t text))))))))

(defun build-system-prompt (&optional force-agents-reload)
  "构造本轮 System Prompt：静态前缀 *system-prompt* 原样保留以命中 prompt cache，
项目纲领 Agents.md 追加在末尾。纲领缺失时退化为原始 *system-prompt*。"
  (let ((agents (load-agents-md force-agents-reload)))
    (if agents
        (format nil "~A~%~%## 项目纲领（Agents.md · 每轮自动注入）~%~%~A"
                *system-prompt* agents)
        *system-prompt*)))

;;; ── 消息 content 归一化与空回答诊断 ─────────────────

(defun block-type (block)
  "安全获取消息块的 type 字段。非 hash-table 或缺失时返回 nil。"
  (when (hash-table-p block)
    (let ((ty (jget block "type")))
      (if (stringp ty) ty nil))))

(defun content-as-blocks (content)
  "把 assistant 的 content 规范化为 block 列表。
兼容 nil / 字符串 / vector / 列表 四种形态，避免因端点返回 string 导致「回答 0 字符」。"
  (cond
    ((null content) nil)
    ((stringp content)
     (if (> (length content) 0)
         (list (jobj "type" "text" "text" content))
         nil))
    ((vectorp content) (coerce content 'list))
    ((listp content)
     (mapcar (lambda (c)
               (if (stringp c)
                   (jobj "type" "text" "text" c)
                   c))
             content))
    (t nil)))

(defun collect-answer-text (content)
  "拼接所有 text 块（忽略 thinking / tool_use 等其它块），返回去除首尾空白的文本。"
  (let ((parts nil))
    (dolist (b (content-as-blocks content))
      (when (and (hash-table-p b)
                 (equal (block-type b) "text")
                 (stringp (jget b "text")))
        (push (jget b "text") parts)))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (format nil "~{~A~^~%~}" (nreverse parts)))))

(defun describe-content-blocks (content)
  "生成 content block 类型摘要，用于诊断「空回答」。"
  (let ((types (mapcar (lambda (b) (or (block-type b) "unknown"))
                       (content-as-blocks content))))
    (if types
        (format nil "~{~A~^,~}" types)
        "空")))

(defun make-continue-nudge (stop-reason)
  "构造一条「请补充文本回答」的用户消息，用于空回答时自动追问。"
  (let ((text (if (member stop-reason '("max_tokens" "length") :test #'string=)
                  "你上一条回复因为输出长度上限被截断，并且没有产生任何文本内容。请直接输出最终的中文文本答案（除非确实必须，否则不要再调用工具）。"
                  "你上一条回复没有任何文本内容（既没有文本，也没有有效的工具调用）。请直接用中文文本回答用户的问题或说明当前进展，禁止返回空回复。")))
    (jobj "role" "user"
          "content" (list (jobj "type" "text" "text" text)))))

;;; ── 热重载错误的记录与注入 ───────────────────────────

(defun safe-check-and-hot-reload ()
  "永不抛错的热重载检查（热重载引擎缺失或异常时也不影响 Agent 任务）。"
  (when (fboundp 'check-and-hot-reload-modified-files)
    (handler-case (funcall 'check-and-hot-reload-modified-files)
      (serious-condition (e)
        (format *error-output* "  [!] 热重载检查异常（已忽略）: ~A~%" e))))
  nil)

(defun reload-error-note ()
  "取出待注入的热重载错误并组装为系统提示；无错误返回 nil。"
  (when (fboundp 'drain-lisp-reload-errors)
    (let ((errs (ignore-errors (funcall 'drain-lisp-reload-errors))))
      (when errs
        (format nil "<system-reminder>~%## Lisp 热重载失败（已自动回滚，任务继续）~%~{~A~%~}~%以上文件已被自动回滚到「上一个可用版本」，工具与核心函数仍在正常工作。请阅读错误、修复源码，然后用 write_file 重新写入。~%</system-reminder>"
                errs)))))

(defun tool-result-block-p (block)
  (and (hash-table-p block) (equal (block-type block) "tool_result")))

(defun inject-note-into-message-flow (messages note)
  "把 note 注入消息流，尽量不破坏 tool_use / tool_result 配对结构。
优先追加到最后一条 tool_result 的 content 里；否则追加为最后一条 user 消息的文本块，
或新增一条 user 消息。返回新的消息列表（不修改原消息对象）。"
  (if (null messages)
      (list (jobj "role" "user" "content" (list (jobj "type" "text" "text" note))))
      (let* ((last (car (last messages)))
             (role (and (hash-table-p last) (jget last "role")))
             (content (and (hash-table-p last) (jget last "content")))
             (tr-blocks (and (listp content)
                             (remove-if-not #'tool-result-block-p content)))
             (new-last
               (cond
                 (tr-blocks
                  (let* ((target (car (last tr-blocks)))
                         (old (jget target "content"))
                         (old-text (if (stringp old)
                                       old
                                       (or (ignore-errors (json-encode old)) "")))
                         (merged (format nil "~A~%~%~A" old-text note))
                         (replaced (jobj "type" "tool_result"
                                         "tool_use_id" (jget target "tool_use_id")
                                         "content" merged)))
                    (when (jget target "is_error")
                      (setf (jget replaced "is_error") (jget target "is_error")))
                    (jobj "role" role
                          "content" (mapcar (lambda (b)
                                              (if (eq b target) replaced b))
                                            content))))
                 ((equal role "user")
                  (jobj "role" role
                        "content" (list (jobj "type" "text"
                                              "text" (if (stringp content)
                                                         content
                                                         (format nil "~A" content)))
                                        (jobj "type" "text" "text" note))))
                 (t
                  (jobj "role" "user"
                        "content" (list (jobj "type" "text" "text" note)))))))
        (append (butlast messages) (list new-last)))))

;;; ── 修复孤立的 tool_use 配对 ─────────────────────────

(defun extract-tool-use-ids (msg)
  "提取 assistant 消息中的所有 tool_use ID。"
  (let ((ids nil)
        (content (and (hash-table-p msg) (jget msg "content"))))
    (when (listp content)
      (dolist (b content)
        (when (and (hash-table-p b)
                   (equal (block-type b) "tool_use")
                   (jget b "id"))
          (push (jget b "id") ids))))
    (nreverse ids)))

(defun extract-tool-result-ids (msg)
  "提取 user 消息中的所有 tool_result ID 集合。"
  (let ((ht (make-hash-table :test 'equal))
        (content (and (hash-table-p msg) (jget msg "content"))))
    (when (listp content)
      (dolist (b content)
        (when (and (hash-table-p b)
                   (equal (block-type b) "tool_result")
                   (jget b "tool_use_id"))
          (setf (gethash (jget b "tool_use_id") ht) t))))
    ht))

(defun fix-missing-tool-results (messages)
  "扫描并修复缺失配对的 tool_result，返回修复后的新消息列表。"
  (let ((out nil)
        (rest messages))
    (loop while rest
          for msg = (pop rest)
          for next-msg = (first rest)
          do (push msg out)
             (when (equal (jget msg "role") "assistant")
               (let ((use-ids (extract-tool-use-ids msg)))
                 (when use-ids
                   (let* ((has-next-user (and next-msg (equal (jget next-msg "role") "user")))
                          (res-ids (if has-next-user (extract-tool-result-ids next-msg) (make-hash-table :test 'equal)))
                          (missing (remove-if (lambda (id) (gethash id res-ids)) use-ids)))
                     (when missing
                       (let ((synthetic (mapcar (lambda (id)
                                                  (jobj "type" "tool_result"
                                                        "tool_use_id" id
                                                        "content" "[警告] 此工具调用未完成（会话中断/恢复）。请忽略并继续。"))
                                                missing)))
                         (format t "~A 修复了 ~D 个缺失的 tool_result~%" (ui-tag-warn "警告") (length missing))
                         (push (jobj "role" "user" "content" synthetic) out))))))))
    (nreverse out)))

;;; ── 控制台日志（CMD 友好：不使用 emoji） ─────────────

(defparameter *log-rule-width* 40
  "分隔线宽度。")

(defun log-line (fmt &rest args)
  "输出一行日志并立即刷新。"
  (apply #'format t fmt args)
  (finish-output))

(defun log-rule ()
  (make-string *log-rule-width* :initial-element #\─))

(defun log-clip (s maxlen)
  "截断过长文本，避免刷屏。"
  (let ((s (or s "")))
    (if (> (length s) maxlen)
        (concatenate 'string (subseq s 0 maxlen) "…")
        s)))

(defun format-tool-args-line (args-ht)
  "把工具参数整理成 `键=值  键=值` 的单行摘要。"
  (if (not (hash-table-p args-ht))
      ""
      (let ((pairs '()))
        (maphash (lambda (k v)
                   (push (format nil "~A=~A" k
                                 (cond
                                   ((stringp v)
                                    (log-clip (substitute #\Space #\Newline v) 38))
                                   ((eq v t) "true")
                                   ((eq v :false) "false")
                                   (t (princ-to-string v))))
                         pairs))
                 args-ht)
        (format nil "~{~A~^  ~}" (nreverse pairs)))))

(defparameter *tool-result-max-chars* 6000
  "单条工具结果进入上下文的最大字符数，超出则截断，避免历史膨胀拖慢每一轮。")

(defun clip-tool-result (s &optional tool-name)
  "工具结果写入上下文时定型：小结果原样保留，大结果 head + omit + tail。
   在写入历史时就裁剪（而非每次请求时改写），保证历史追加式、前缀稳定。"
  (if (fboundp 'elide-tool-result)
      (funcall 'elide-tool-result s tool-name)
      s))

;;; ── 工具执行 ─────────────────────────────────────────

(defun execute-tool-use-block (tool-use &optional turn)
  "执行单个 tool_use 块，返回对应的 tool_result 块；同时打印简洁的执行日志。
支持执行期间按 ESC 实时中断，以及超时自动熔断（Watchdog），防止死循环卡死主线程。"
  (let* ((t-id (or (jget tool-use "id") (format nil "toolu_~D" (get-universal-time))))
         (t-name (or (jget tool-use "name") "(unknown)"))
         (t-input (let ((in (jget tool-use "input")))
                    (if (hash-table-p in) in (jobj))))
         (args-line (format-tool-args-line t-input))
         (timeout (if (string= t-name "eval_lisp")
                      (if (boundp '*eval-lisp-timeout-seconds*) *eval-lisp-timeout-seconds* 15)
                      (if (boundp '*default-tool-timeout-seconds*) *default-tool-timeout-seconds* 30)))
         (start (get-internal-real-time)))
    (log-line "~A ~A ~A~@[ ~A~]~%"
              (ui-dim (format nil "[~2,'0D]" (or turn 0)))
              (ui-dim ">")
              (ui-colorize "1;36" t-name)
              (if (zerop (length args-line)) nil (ui-dim args-line)))
    (handler-case
        (multiple-value-bind (res status diagnostic)
            (if (fboundp 'call-tool-with-cancel-and-timeout)
                (funcall 'call-tool-with-cancel-and-timeout
                         (lambda () (funcall 'execute-tool t-name t-input))
                         :timeout timeout
                         :tool-name t-name
                         :args-summary args-line)
                (values (funcall 'execute-tool t-name t-input) :done nil))
          (let* ((ms (round (* 1000 (/ (- (get-internal-real-time) start)
                                       internal-time-units-per-second))))
                 (stalled-p (member status '(:timeout :rollback)))
                 (repeated-loop-p
                   (and (fboundp 'record-turn-tool-signature)
                        (funcall 'record-turn-tool-signature t-name args-line stalled-p)))
                 (loop-note
                   (when repeated-loop-p
                     (and (fboundp 'maybe-intervene-turn-loop)
                          (funcall 'maybe-intervene-turn-loop t-name args-line)))))
            (cond
              ((eq status :cancelled)
               (log-line "    ~A ~D ms · 用户按 ESC 中断工具执行~%" (ui-tag-warn "中断") ms)
               (make-cancelled-tool-result tool-use))
              ((eq status :rollback)
               (let ((rmsg (format nil "[督导回退] 督导子 Agent 检测到死循环并已程序化回滚代码 (~A, ~D ms):~%~A~@[~%~%~A~]"
                                   t-name ms (or diagnostic "") loop-note)))
                 (log-line "    ~A ~D ms · 督导子 Agent 已回滚未验证代码并中断死循环~%"
                           (ui-tag-warn "督导回退") ms)
                 (jobj "type" "tool_result"
                       "tool_use_id" t-id
                       "is_error" t
                       "content" rmsg)))
              ((eq status :timeout)
               (let ((tmsg (format nil "[督导熔断] 督导子 Agent 判定工具 ~A 陷入死循环 (~D ms):~%~A~%~%-> 请根据上方实时 SBCL 调用栈定位死循环原因，改用非阻塞纯函数方式测试。~@[~%~%~A~]"
                                   t-name ms
                                   (or diagnostic
                                       (format nil "执行超过 ~D 秒无进展" timeout))
                                   loop-note)))
                 (log-line "    ~A ~D ms · 督导子 Agent 熔断死循环~%" (ui-tag-err "督导熔断") ms)
                 (jobj "type" "tool_result"
                       "tool_use_id" t-id
                       "is_error" t
                       "content" tmsg)))
              (t
               (let* ((res-str (if (stringp res) res (json-encode res)))
                      (final-str (if loop-note
                                     (format nil "~A~%~%~A" (clip-tool-result res-str t-name) loop-note)
                                     (clip-tool-result res-str t-name)))
                      (head (let* ((trimmed (string-left-trim '(#\Space #\Tab #\Return #\Newline) res-str))
                                   (json-p (and (> (length trimmed) 0)
                                                (member (char trimmed 0) '(#\{ #\[)))))
                              (unless json-p
                                (let ((nl (position #\Newline trimmed)))
                                  (log-clip (if nl (subseq trimmed 0 nl) trimmed) 40))))))
                 (if head
                     (log-line "    ~A ~A~%" (ui-dim "<")
                               (ui-dim (format nil "~A 字符 · ~D ms · ~A" (length res-str) ms head)))
                     (log-line "    ~A ~A~%" (ui-dim "<")
                               (ui-dim (format nil "~A 字符 · ~D ms" (length res-str) ms))))
                 (jobj "type" "tool_result"
                       "tool_use_id" t-id
                       "content" final-str))))))
      (error (e)
        (let ((ms (round (* 1000 (/ (- (get-internal-real-time) start)
                                    internal-time-units-per-second)))))
          (log-line "    ~A ~D ms · ~A~%" (ui-tag-err "失败") ms e)
          (jobj "type" "tool_result"
                "tool_use_id" t-id
                "is_error" t
                "content" (format nil "工具执行失败: ~A" e)))))))

;;; ── ESC 中断与 Agent 主循环 ─────────────────────────

(defun agent-cancelled-p ()
  "是否已收到用户中断请求（cancel 模块未加载时恒为 nil）。"
  (and (fboundp 'agent-cancel-requested-p)
       (ignore-errors (funcall 'agent-cancel-requested-p))))

(defun cancel-support-available-p ()
  "当前是否具备「按 ESC 中断执行中任务」的能力。"
  (and (fboundp 'interactive-cancel-available-p)
       (ignore-errors (funcall 'interactive-cancel-available-p))))

(defun call-llm-with-cancel (thunk)
  "调用模型；具备中断能力时把请求放到后台线程，主线程轮询 ESC。
返回 (values 响应 :done) 或 (values nil :cancelled)。"
  (if (fboundp 'call-with-cancel-polling)
      (funcall 'call-with-cancel-polling thunk)
      (values (funcall thunk) :done)))

(defun make-cancelled-tool-result (tool-use)
  "中断后为未执行的 tool_use 生成占位 tool_result，保持调用链配对完整。"
  (jobj "type" "tool_result"
        "tool_use_id" (or (jget tool-use "id") "toolu_cancelled")
        "is_error" t
        "content" "[已中断] 用户按 ESC 中止了本次任务，此工具未执行。"))

(defun ensure-trailing-assistant (messages)
  "中断后若最后一条消息不是 assistant，补一条说明，避免出现连续两条 user 消息。"
  (let ((last (car (last messages))))
    (if (or (null last)
            (and (hash-table-p last) (equal (jget last "role") "assistant")))
        messages
        (append messages
                (list (jobj "role" "assistant"
                            "content" (list (jobj "type" "text"
                                                  "text" "（本次任务已被用户中断，未完成。）"))))))))

(defun make-cancelled-result (messages in-tokens out-tokens turns tool-calls)
  "构造「已中断」的返回值：完整保留已经产生的上下文调用链。"
  (let ((msgs (ensure-trailing-assistant messages)))
    (list :answer (format nil "已中断（第 ~D 轮，已完成 ~D 次工具调用）。上下文已保留 ~D 条消息，可直接继续提问。"
                          turns tool-calls (length msgs))
          :history msgs
          :input-tokens in-tokens
          :output-tokens out-tokens
          :cancelled t)))

;;; ── Agent 主循环 ─────────────────────────────────────

(defun run-agent-core (user-input &optional history)
  "执行一次完整的 ReAct Agent 对话循环。
返回 plist: (:answer string :history list :input-tokens int :output-tokens int [:cancelled t])

执行期间用户按 ESC 会中断当前任务：
- 已经完成的轮次（assistant 回复 + tool_result）全部保留在 :history 里；
- 未执行完的 tool_use 会补一条「已中断」的 tool_result，保证调用链结构合法；
- 返回 :cancelled t，CLI 端据此给出提示但不清空会话历史。"
  (when *auto-reload-before-turn* (safe-check-and-hot-reload))

  (when (fboundp 'reset-ctx-run-stats) (reset-ctx-run-stats))
  (when (fboundp 'reset-cancel-state) (funcall 'reset-cancel-state))
  (when (fboundp 'reset-supervisor-session) (funcall 'reset-supervisor-session))

  ;; CLI 交互模式下：先把用户消息以醒目样式回显到历史里，便于滚动时定位。
  ;; 放在 run-agent（而不是 start-cli）是为了热重载后立即生效：
  ;; start-cli 的主循环是已编译代码，新增调用要重启才生效。
  (when (and (fboundp 'cli-echo-user-message)
             (boundp '*raw-console-active*)
             (symbol-value '*raw-console-active*))
    (ignore-errors (funcall 'cli-echo-user-message user-input)))

  (let ((*agent-busy* t))
    (let* ((env-ctx (build-environment-context))
           (enriched-input (format nil "~A~%~%---~%~%~A" env-ctx user-input))
           (messages (fix-missing-tool-results
                      (append (copy-list history)
                              (list (jobj "role" "user" "content" enriched-input)))))
           (turns 0)
           (tool-calls 0)
           (empty-retries 0)
           (total-in-tokens 0)
           (total-out-tokens 0))

      (when (cancel-support-available-p)
        (log-line "~A 执行中按 ESC 可中断本次任务，已产生的上下文会保留~%~%"
                  (ui-dim "提示")))

      (loop while (or (null *max-turns*) (< turns *max-turns*))
            do (incf turns)
               (when (fboundp 'poll-user-cancel) (funcall 'poll-user-cancel))
               (when *auto-reload-before-turn* (safe-check-and-hot-reload))
               (let ((note (reload-error-note)))
                 (when note
                   (setf messages (inject-note-into-message-flow messages note))))

               (setf messages (compact-history-if-needed messages turns))

               (let* ((req-start (get-internal-real-time))
                      (all-tools (get-all-tool-definitions)))
                 (multiple-value-bind (response call-status)
                     (labels ((invoke-llm ()
                                (call-llm-with-cancel
                                 (lambda ()
                                   (funcall 'chat-with-tools
                                            :system (build-system-prompt)
                                            :messages messages
                                            :tools all-tools)))))
                       (handler-case
                           (invoke-llm)
                         (error (e)
                           ;; 若本轮存在刚热重载但尚未通过通信验证的代码，运行期报错时立即自动回滚并重试一次
                           (if (and (fboundp 'unverified-lisp-backups-p)
                                    (funcall 'unverified-lisp-backups-p)
                                    (fboundp 'rollback-unverified-lisp-files))
                               (progn
                                 (funcall 'rollback-unverified-lisp-files e)
                                 (let ((heal-note (reload-error-note)))
                                   (when heal-note
                                     (setf messages (inject-note-into-message-flow messages heal-note))))
                                 (setf all-tools (funcall 'get-all-tool-definitions))
                                 (invoke-llm))
                               (error e)))))
                   (when (eq call-status :cancelled)
                     (log-line "~%~A 第 ~D 轮请求已中断，上下文已保留~%"
                               (ui-tag-warn "中断") turns)
                     (return-from run-agent-core
                       (make-cancelled-result messages total-in-tokens total-out-tokens
                                              turns tool-calls)))
                   ;; LLM 请求成功返回 → 确认此前热重载的代码未破坏核心通信链路
                   (when (fboundp 'commit-verified-lisp-backups)
                     (ignore-errors (funcall 'commit-verified-lisp-backups)))
                   (let* ((usage (jget response "usage"))
                          (in-tok (if (hash-table-p usage) (or (jget usage "input_tokens") 0) 0))
                          (out-tok (if (hash-table-p usage) (or (jget usage "output_tokens") 0) 0))
                          (stop-reason (let ((sr (jget response "stop_reason")))
                                         (if (stringp sr) sr "end_turn")))
                          (content (content-as-blocks (jget response "content")))
                          (tool-uses (remove-if-not
                                      (lambda (b) (equal (block-type b) "tool_use"))
                                      content)))

                     (log-line "~A 第 ~D 轮 · 模型 ~D ms · 上下文 ~D 条~%"
                               (ui-dim "·") turns
                               (round (* 1000 (/ (- (get-internal-real-time) req-start)
                                                 internal-time-units-per-second)))
                               (length messages))
                     (incf total-in-tokens in-tok)
                     (when (fboundp 'log-context-usage)
                       (log-context-usage usage messages turns))
                     (incf total-out-tokens out-tok)
                     (setf messages (append messages (list (jobj "role" "assistant" "content" content))))

                     (cond
                       ;; ① 存在 tool_use → 无论 stop_reason 是什么都执行
                       (tool-uses
                        (log-line "~A 第 ~D 轮 ~A~%"
                                  (ui-colorize "1;36" "──") turns (ui-dim (log-rule)))
                        (when (and (not (equal stop-reason "tool_use"))
                                   (not (equal stop-reason "max_tokens")))
                          (log-line "    (stop_reason=~A，按工具调用处理)~%" stop-reason))
                        (let ((tool-results nil))
                          (dolist (tc tool-uses)
                            (incf tool-calls)
                            (when (fboundp 'poll-user-cancel) (funcall 'poll-user-cancel))
                            (push (if (agent-cancelled-p)
                                      (make-cancelled-tool-result tc)
                                      (execute-tool-use-block tc turns))
                                  tool-results))
                          (setf messages
                                (append messages
                                        (list (jobj "role" "user"
                                                    "content" (nreverse tool-results))))))
                        ;; 工具执行期间按 ESC → 立刻收尾返回，保留已完成的调用链
                        (when (fboundp 'poll-user-cancel) (funcall 'poll-user-cancel))
                        (when (agent-cancelled-p)
                          (log-line "~%~A 工具执行已中断，上下文已保留~%"
                                    (ui-tag-warn "中断"))
                          (return-from run-agent-core
                            (make-cancelled-result messages total-in-tokens total-out-tokens
                                                   turns tool-calls))))

                       ;; ② 无工具调用 → 提取文本答案
                       (t
                        (let ((answer (collect-answer-text content)))
                          (cond
                            ;; 正常回答
                            ((> (length answer) 0)
                             (let ((total-tok (+ total-in-tokens total-out-tokens)))
                               (log-line "~%~A 回答 ~D 字符 · ~D 轮 · ~D 次工具调用 · 共 ~D tokens (in ~D / out ~D)~%"
                                         (ui-tag-ok "完成")
                                         (length answer) turns tool-calls total-tok
                                         total-in-tokens total-out-tokens)
                               (return-from run-agent-core
                                 (list :answer answer
                                       :history messages
                                       :input-tokens total-in-tokens
                                       :output-tokens total-out-tokens))))

                            ;; 空回答 → 自动追问（有限次）
                            ((< empty-retries *max-empty-answer-retries*)
                             (incf empty-retries)
                             (log-line "~A 本轮无文本输出 (blocks=~A)，自动追问 ~D/~D~%"
                                       (ui-tag-warn "警告")
                                       (describe-content-blocks content)
                                       empty-retries *max-empty-answer-retries*)
                             (setf messages (append messages (list (make-continue-nudge stop-reason)))))

                            ;; 仍为空 → 返回可读诊断
                            (t
                             (let ((diagnostic
                                     (format nil "模型在本轮未返回任何文本内容（stop_reason=~A，content blocks=[~A]）。可能原因：输出被截断、模型只返回了思考/工具块、或服务端响应异常。建议重试本次提问；若持续出现，可用 /reload 检查配置或 /model 重新确认 Key。"
                                             stop-reason (describe-content-blocks content))))
                               (log-line "~A ~A~%" (ui-tag-warn "警告") diagnostic)
                               (return-from run-agent-core
                                 (list :answer diagnostic
                                       :history messages
                                       :input-tokens total-in-tokens
                                       :output-tokens total-out-tokens))))))))))))

    ;; 只有在 *max-turns* 为整数且已耗尽时才会走到这里
    (let ((last-text (collect-answer-text
                      (let ((last-msg (car (last messages))))
                        (and (hash-table-p last-msg) (jget last-msg "content"))))))
      (list :answer (if (> (length last-text) 0)
                        last-text
                        (format nil "已达设定的轮数上限（~D 轮，累计 ~D 次工具调用），任务尚未收敛；可用 /turns off 取消上限后继续。"
                                *max-turns* tool-calls))
            :history messages
            :input-tokens total-in-tokens
            :output-tokens total-out-tokens))))
)


;;; ── 自监管迭代：前后台互斥包装 ───────────────────────
;;; 真正的 ReAct 循环在 run-agent-core 中；run-agent 只负责在任务执行期间
;;; 给空闲自省子 Agent 打上「前台忙」标记，保证两者不会同时调用 LLM。

(defun run-agent (user-input &optional history)
  "执行一次完整的 ReAct Agent 对话循环（带前后台互斥标记）。"
  (when (fboundp 'self-iteration-observe-user-input)
    (funcall 'self-iteration-observe-user-input user-input))
  (when (fboundp 'self-iteration-begin-task)
    (funcall 'self-iteration-begin-task))
  (unwind-protect
       (run-agent-core user-input history)
    (when (fboundp 'self-iteration-end-task)
      (funcall 'self-iteration-end-task))))
