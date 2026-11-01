;;;; lisp/context-manager.lisp
;;;; 上下文压缩器：head + omit + tail（主流 micro-compaction 做法）
;;;; DeepSeek 前缀缓存优化：追加式历史 / 惰性压缩 / 幂等省略 / 命中率观测

(in-package :cl-user)

;;; ── 参数 ─────────────────────────────────────────────

(defparameter *ctx-max-prompt-chars* 800000
  "触发消息级压缩的硬阈值（约 300k tokens，占 1M 窗口约 30%）。低于此值只做单条工具结果的 head/omit/tail。
    可用 MYAGENT_COMPACT_CHARS 覆盖；换用小窗口模型（128K）时应下调到 120000 左右。")

(defun ctx-compact-threshold ()
  "实际生效的消息级压缩阈值：MYAGENT_COMPACT_CHARS（.env 或系统环境变量）优先，否则用 *ctx-max-prompt-chars*。"
  (or (let ((v (and (fboundp 'get-env)
                    (ignore-errors (get-env "MYAGENT_COMPACT_CHARS")))))
        (and v (let ((n (ignore-errors (parse-integer v))))
                 (and n (plusp n) n))))
      *ctx-max-prompt-chars*))

(defparameter *ctx-hysteresis* 1.5
  "压缩后再增长 50% 才允许二次压缩，尽量拉长两次前缀重写之间的间隔，少打掉 DeepSeek 缓存。")

(defparameter *ctx-head-messages* 3
  "消息级压缩时原样保留的头部消息数（首条用户任务 + 最初的动作锚点）。")

(defparameter *ctx-tail-messages* 12
  "消息级压缩时原样保留的尾部消息数（最近约 6 轮完整上下文）。")

(defparameter *ctx-summary-max-chars* 6000
  "被省略中段生成的结构化摘要最大字符数。")

(defparameter *ctx-chars-per-token* 2.6
  "中英混合内容的字符/token 估算系数（仅用于日志与阈值判断）。")

(defparameter *ctx-omit-marker* "[...已省略中间"
  "省略标记；用于幂等判断，已省略过的内容不再二次截断。")

(defparameter *ctx-tier-small* 16000
  "工具结果不超过该长度时原样保留（小结果不裁剪以保持字节稳定、利于缓存复用）。")

(defparameter *ctx-tier-mid* 40000
  "工具结果不超过该长度时使用中档 head/tail，超过则用紧凑档。")

(defparameter *ctx-log* t
  "是否打印压缩与缓存统计日志。")

(defvar *ctx-compactions* 0)
(defvar *ctx-chars-after-compact* 0)
(defvar *ctx-run-cache-hit* 0)
(defvar *ctx-run-cache-miss* 0)

(defvar *ctx-last-prompt-tokens* 0
  "上一轮实际发送给模型的 prompt token 数（cache_read + 未命中部分）。")

(defvar *ctx-last-prompt-chars* 0
  "上一轮消息体的字符数估算。")

(defvar *ctx-session-cache-hit* 0)
(defvar *ctx-session-cache-miss* 0)
(defvar *ctx-session-requests* 0)

;;; ── 基础读取工具 ─────────────────────────────────────

(defun ctx-get (block key)
  (when (hash-table-p block) (ignore-errors (jget block key))))

(defun ctx-type (block)
  (let ((ty (ctx-get block "type"))) (and (stringp ty) ty)))

(defun ctx-role (msg)
  (let ((r (ctx-get msg "role"))) (and (stringp r) r)))

(defun ctx-blocks (msg)
  (let ((c (ctx-get msg "content")))
    (cond ((null c) nil)
          ((stringp c) (list (jobj "type" "text" "text" c)))
          ((vectorp c) (coerce c 'list))
          ((listp c) c)
          (t nil))))

(defun ctx-str-len (x)
  (cond ((null x) 0)
        ((stringp x) (length x))
        ((or (hash-table-p x) (listp x))
         (length (or (ignore-errors (json-encode x)) "")))
        (t (length (princ-to-string x)))))

(defun ctx-messages-chars (messages)
  "估算消息序列的字符规模（文本 + 工具参数 + 工具结果）。"
  (loop for m in messages
        sum (loop for b in (ctx-blocks m)
                  sum (+ (ctx-str-len (ctx-get b "text"))
                         (ctx-str-len (ctx-get b "content"))
                         (ctx-str-len (ctx-get b "input"))))))

(defun ctx-tokens (chars)
  (round (/ (float chars 1.0) *ctx-chars-per-token*)))

;;; ── 文本级 head + omit + tail ────────────────────────

(defun ctx-line-start (s pos)
  "返回 pos 所在行的行首位置（不在行中间切断）。"
  (let* ((pos (max 0 (min pos (length s))))
         (nl (position #\Newline s :end pos :from-end t)))
    (if nl (1+ nl) 0)))

(defun ctx-line-end (s pos)
  "返回 pos 之后第一个换行的位置，确保 head 以整行结束。"
  (let* ((pos (max 0 (min pos (length s))))
         (nl (position #\Newline s :start pos)))
    (or nl (length s))))

(defun elide-middle-text (s head tail &optional (label "内容"))
  "保留头 head 字符、尾 tail 字符，中间替换为省略标记；幂等。"
  (let ((len (length s)))
    (if (or (<= len (+ head tail 400))
            (search *ctx-omit-marker* s))
        s
        (let* ((he (ctx-line-end s head))
               (ts (ctx-line-start s (- len tail)))
               ;; 无换行（压缩后的 JSON / base64 / 单行日志）时行锚点会退化，改用硬字符切分
               (he (if (< he ts) he (min head (- len tail))))
               (ts (if (< he ts) ts (max he (- len tail)))))
          (if (or (>= he ts) (< (- ts he) 200))
              s
              (let ((omitted (- ts he))
                    (lines (1+ (count #\Newline s :start he :end ts))))
                (format nil "~A~%~%[...已省略中间 ~D 行 / ~D 字符（原始 ~D 字符，~A）。如需细节请重新调用工具按范围读取，不要假设未展示的内容...]~%~%~A"
                        (subseq s 0 he) lines omitted len label
                        (subseq s ts))))))))

(defun elide-tool-result (s &optional tool-name)
  "工具结果写入历史时定型：小结果原样保留，大结果 head + omit + tail。
   写入即定型 => 历史保持追加式，后续每轮前缀完全一致，DeepSeek 缓存可持续命中。"
  (if (or (not (stringp s))
          (<= (length s) *ctx-tier-small*)
          (search *ctx-omit-marker* s))
      s
      (let ((len (length s))
            (label (if (and (stringp tool-name) (> (length tool-name) 0))
                       (format nil "工具 ~A 输出" tool-name)
                       "工具输出")))
        (if (<= len *ctx-tier-mid*)
            (elide-middle-text s 8000 2000 label)
            (elide-middle-text s 4000 1200 label)))))

;;; ── 消息级摘要 ───────────────────────────────────────

(defun ctx-brief-text (s n)
  (let ((s (substitute #\Space #\Newline (or s ""))))
    (if (> (length s) n)
        (concatenate 'string (subseq s 0 n) "…")
        s)))

(defun ctx-brief-input (ht)
  (if (not (hash-table-p ht))
      ""
      (let ((parts nil))
        (dolist (k '("filePath" "dirPath" "path" "pattern" "searchText" "command" "target"))
          (let ((v (ignore-errors (jget ht k))))
            (when (stringp v)
              (push (format nil "~A=~A" k (ctx-brief-text v 50)) parts))))
        (if parts (format nil "~{~A~^, ~}" (nreverse parts)) ""))))

(defun ctx-message-brief (msg)
  (let ((parts nil))
    (dolist (b (ctx-blocks msg))
      (let ((ty (ctx-type b)))
        (cond ((equal ty "text")
               (let ((txt (ctx-get b "text")))
                 (when (and (stringp txt) (> (length txt) 0))
                   (push (ctx-brief-text txt 120) parts))))
              ((equal ty "tool_use")
               (push (format nil "调用 ~A(~A)" (ctx-get b "name")
                             (ctx-brief-input (ctx-get b "input")))
                     parts))
              ((equal ty "tool_result")
               (push (format nil "结果 ~D 字符" (ctx-str-len (ctx-get b "content")))
                     parts)))))
    (format nil "[~A] ~A" (or (ctx-role msg) "?")
            (if parts (format nil "~{~A~^ | ~}" (nreverse parts)) "空"))))

(defun ctx-build-digest (dropped)
  "把被省略的中段压成结构化摘要（工具名 + 参数 + 结果规模）。"
  (with-output-to-string (o)
    (let ((budget *ctx-summary-max-chars*) (n 0))
      (dolist (m dropped)
        (let ((line (ctx-message-brief m)))
          (when (<= (+ (length line) 1) budget)
            (format o "- ~A~%" line)
            (decf budget (1+ (length line)))
            (incf n))))
      (when (< n (length dropped))
        (format o "- ……其余 ~D 条消息已省略（工具参数与结果原文，需要时请重新读取）~%"
                (- (length dropped) n))))))

;;; ── 消息级 head + omit + tail ────────────────────────

(defun ctx-append-block (msg block)
  "把 block 追加到消息 content 末尾：用于把压缩摘要并入相邻 user 消息，保持 role 交替合法。"
  (let ((c (ctx-get msg "content")))
    (jobj "role" (or (ctx-role msg) "user")
          "content" (if (stringp c)
                        (list (jobj "type" "text" "text" c) block)
                        (append (ctx-blocks msg) (list block))))))

(defun ctx-assistant-tool-use-p (msg)
  (and (equal (ctx-role msg) "assistant")
       (some (lambda (b) (equal (ctx-type b) "tool_use")) (ctx-blocks msg))))

(defun compact-history (messages &key (head-n *ctx-head-messages*)
                                     (tail-n *ctx-tail-messages*))
  "对历史做 head + omit + tail：头部与尾部原样保留，中段折叠为一条摘要消息。
   返回 (values 新列表 省略条数 节省字符)；条件不满足时返回 (values nil 0 0)。
   切割点保证不拆散 tool_use / tool_result 配对。"
  (let ((len (length messages)))
    (if (<= len (+ head-n tail-n 2))
        (values nil 0 0)
        (let ((he (min len head-n)))
          ;; head 不能停在带 tool_use 的 assistant 上（否则其 tool_result 被孤立）
          (loop while (and (< he len)
                           (ctx-assistant-tool-use-p (nth (1- he) messages)))
                do (incf he))
          (let ((ts (max he (- len tail-n))))
            ;; tail 必须从 assistant 消息开始，确保摘要(user) → assistant 结构合法
            (loop while (and (< ts len)
                             (not (equal (ctx-role (nth ts messages)) "assistant")))
                  do (incf ts))
            (if (or (>= ts len) (<= ts he))
                (values nil 0 0)
                (let* ((dropped (subseq messages he ts))
                       (before (ctx-messages-chars messages))
                       (text (format nil "<compacted-history>~%[上下文压缩] 为控制上下文长度，历史中第 ~D 至 ~D 条消息（共 ~D 条）的原文已省略，以下为结构化摘要：~%~%~A~%以上为摘要；如需细节请重新调用工具读取，不要假设未展示的内容。~%</compacted-history>"
                                     (1+ he) ts (length dropped)
                                     (ctx-build-digest dropped)))
                       (summary-block (jobj "type" "text" "text" text))
                       (summary (jobj "role" "user" "content" (list summary-block)))
                       (head-msgs (subseq messages 0 he))
                       (new (let ((last-head (car (last head-msgs))))
                              (if (equal (ctx-role last-head) "user")
                                  (append (butlast head-msgs)
                                          (list (ctx-append-block last-head summary-block))
                                          (subseq messages ts))
                                  (append head-msgs (list summary) (subseq messages ts)))))
                       (after 0))
                  (when (fboundp 'fix-missing-tool-results)
                    (setf new (or (ignore-errors (funcall 'fix-missing-tool-results new)) new)))
                  (setf after (ctx-messages-chars new))
                  (values new (length dropped) (- before after)))))))))

(defun compact-history-if-needed (messages &optional (turn 0))
  "超过硬阈值且满足滞后条件时才压缩一次（压缩即一次性重写前缀，之后恢复追加式）。"
  (let ((chars (ctx-messages-chars messages)))
    (if (or (null messages)
            (<= chars (ctx-compact-threshold))
            (<= chars (* *ctx-chars-after-compact* *ctx-hysteresis*)))
        messages
        (multiple-value-bind (new dropped saved) (compact-history messages)
          (if (null new)
              messages
              (progn
                (incf *ctx-compactions*)
                (setf *ctx-chars-after-compact* (- chars saved))
                (when *ctx-log*
                  (log-line "  ~A 上下文压缩 · 第 ~D 轮 · 省略 ~D 条中间消息 · ~,1FK -> ~,1FK 字符（约 ~,1FK -> ~,1FK tokens，前缀缓存重建一次）~%"
                            (ui-dim "·") turn dropped
                            (/ chars 1000.0) (/ (- chars saved) 1000.0)
                            (/ chars 1000.0 *ctx-chars-per-token*)
                            (/ (- chars saved) 1000.0 *ctx-chars-per-token*)))
                new))))))

;;; ── DeepSeek 缓存命中观测 ────────────────────────────

(defun ctx-int (ht &rest keys)
  (when (hash-table-p ht)
    (loop for k in keys
          for v = (ignore-errors (jget ht k))
          when (and (numberp v) (>= v 0)) return v)))

(defun cache-hit-tokens (usage)
  "兼容 Anthropic 风格 cache_read_input_tokens 与 DeepSeek/OpenAI 风格 prompt_cache_hit_tokens。"
  (ctx-int usage "cache_read_input_tokens" "prompt_cache_hit_tokens" "cache_hit_tokens"))

(defun cache-miss-tokens (usage)
  "缓存未命中的输入 token 数。
   DeepSeek/OpenAI 风格直接给 prompt_cache_miss_tokens；
   Anthropic 风格下 input_tokens 本身就是未缓存部分（cache_read 不计入）。"
  (or (ctx-int usage "prompt_cache_miss_tokens" "cache_miss_tokens")
      (ctx-int usage "input_tokens" "prompt_tokens")))

(defun reset-ctx-run-stats ()
  "新一轮对话开始：先把手头本轮统计并入会话累计，再清零本轮计数。"
  (when (plusp (+ *ctx-run-cache-hit* *ctx-run-cache-miss*))
    (incf *ctx-session-cache-hit* *ctx-run-cache-hit*)
    (incf *ctx-session-cache-miss* *ctx-run-cache-miss*))
  (setf *ctx-compactions* 0
        *ctx-chars-after-compact* 0
        *ctx-run-cache-hit* 0
        *ctx-run-cache-miss* 0)
  nil)

(defun log-context-usage (usage messages &optional turn)
  "打印本轮上下文规模与 DeepSeek 缓存命中率，便于验证前缀缓存是否持续命中。"
  (let* ((chars (ctx-messages-chars messages))
         (hit (cache-hit-tokens usage))
         (miss (cache-miss-tokens usage))
         (prompt-tok (if (plusp (+ (or hit 0) (or miss 0)))
                         (+ (or hit 0) (or miss 0))
                         (or (ctx-int usage "input_tokens" "prompt_tokens") 0))))
    (when hit (incf *ctx-run-cache-hit* hit))
    (when miss (incf *ctx-run-cache-miss* miss))
    (setf *ctx-last-prompt-chars* chars)
    (when (plusp prompt-tok)
      (setf *ctx-last-prompt-tokens* prompt-tok)
      (incf *ctx-session-requests*))
    (let* ((total (when (and hit miss) (+ hit miss)))
           (line (cond ((and total (> total 0))
                        (format nil "缓存命中 ~,1FK/~,1FK (~D%)"
                                (/ hit 1000.0) (/ total 1000.0)
                                (round (* 100.0 (/ hit (float total 1.0))))))
                       ((and hit (> hit 0))
                        (format nil "缓存命中 ~,1FK tokens" (/ hit 1000.0)))
                       (t nil))))
      (when *ctx-log*
        (log-line "    ~A 上下文 ~D 条 · ~,1FK 字符 / 约 ~,1FK tokens~@[ · ~A~]~%"
                  (ui-dim "·") (length messages)
                  (/ chars 1000.0) (/ (ctx-tokens chars) 1000.0) line)))))

;;; ── CLI 底部状态栏（缓存命中率 + 上下文占比） ───────

(defparameter *model-context-windows*
  '(("deepseek-flash" . 1048576)   ; DeepSeek-V4.1-Flash：官方 /models 返回 1M
    ("deepseek-v4-pro" . 1048576)  ; DeepSeek-V4-Pro：官方 /models 返回 1M
    ("deepseek-chat" . 131072)
    ("deepseek-reasoner" . 131072)
    ("deepseek-v3.2" . 131072)
    ("deepseek-v3.1" . 131072)
    ("deepseek-v3" . 65536)
    ("deepseek-r1" . 65536)
    ("deepseek-coder" . 65536))
  "静态兜底表：模型 → 最大上下文（tokens）。按最长前缀匹配。
    真正权威的数值来自官方 /models 接口（见 ctx-fetch-model-metadata），本表只在离线或未收录时兜底；
    仍未命中就不猜：状态栏只显示绝对 token 数，不显示百分比。")

(defparameter *ctx-window-tokens* nil
  "手工覆盖上下文窗口（tokens）；nil 表示按当前模型自动判定。")

(defparameter *ctx-model-metadata-ttl* 3600
  "模型元数据（上下文窗口）缓存有效期，单位秒。默认 1 小时刷新一次。")

(defparameter *ctx-model-metadata-enabled* t
  "是否允许向官方 /models 查询模型窗口。离线环境或不想联网时设为 nil。")

(defvar *ctx-model-window-cache* (make-hash-table :test 'equal)
  "model-id → context_window，来自官方 /models 的权威数值（会话级缓存）。")

(defvar *ctx-model-metadata-time* nil
  "上次尝试拉取 /models 的时间（universal-time）；nil 表示从未尝试。")

(defun ctx-current-model ()
  "当前生效的模型名（.env / 系统环境变量 / CLI /model 配置）。"
  (handler-case
      (let ((cfg (and (fboundp 'resolve-llm-config)
                      (resolve-llm-config :allow-empty-key t))))
        (and cfg (ignore-errors (llm-config-model cfg))))
    (error () nil)))

(defun ctx-models-url (base-url)
  "把 Anthropic 兼容地址（…/anthropic）归一化到 /models 端点。"
  (let* ((b (string-right-trim "/" (or base-url "")))
         (n (length b))
         (b (if (and (>= n 10) (string-equal "/anthropic" b :start2 (- n 10) :end1 10))
                (subseq b 0 (- n 10))
                b)))
    (format nil "~A/models"
            (if (plusp (length b)) b "https://api.deepseek.com"))))

(defun ctx-fetch-model-metadata (&key (timeout 6))
  "向官方 /models 拉取每个模型的 context_window，写入 *ctx-model-window-cache*。
    返回成功写入的模型个数；失败返回 nil（调用方无需处理）。
    无论成败都会刷新 *ctx-model-metadata-time*，避免网络异常时反复阻塞。"
  (setf *ctx-model-metadata-time* (get-universal-time))
  (let* ((cfg (ignore-errors (resolve-llm-config :allow-empty-key t)))
         (key (and cfg (ignore-errors (llm-config-api-key cfg)))))
    (when (and *ctx-model-metadata-enabled* (stringp key) (plusp (length key)))
      (handler-case
          (let* ((url (ctx-models-url (ignore-errors (llm-config-base-url cfg))))
                 (raw (string-trim '(#\Space #\Newline #\Return)
                                   (uiop:run-program
                                    (list "curl" "-sS" "-m" (princ-to-string timeout)
                                          "-H" (format nil "Authorization: Bearer ~A" key) url)
                                    :output :string :error-output :string :ignore-error-status t)))
                 (obj (ignore-errors (json-decode raw)))
                 (items (let ((d (and obj (ignore-errors (jget obj "data")))))
                          (cond ((vectorp d) (coerce d 'list))
                                ((listp d) d)
                                (t nil))))
                 (n 0))
            (dolist (it items)
              (let ((id (and (hash-table-p it) (ignore-errors (jget it "id"))))
                    (cw (and (hash-table-p it) (ignore-errors (jget it "context_window")))))
                (when (and (stringp id) (numberp cw) (plusp cw))
                  (setf (gethash id *ctx-model-window-cache*) (round cw))
                  (incf n))))
            n)
        (error () nil)))))

(defun ctx-model-metadata-stale-p ()
  (or (null *ctx-model-metadata-time*)
      (> (abs (- (get-universal-time) *ctx-model-metadata-time*)) *ctx-model-metadata-ttl*)))

(defun ctx-model-window-static (model)
  "静态表按最长前缀匹配模型名对应的窗口；未收录返回 nil（不猜）。"
  (when (and (stringp model) (plusp (length model)))
    (let ((best nil) (best-len 0))
      (dolist (pair *model-context-windows* best)
        (let ((prefix (car pair)))
          (when (and (>= (length model) (length prefix))
                     (string-equal prefix model :end2 (length prefix))
                     (> (length prefix) best-len))
            (setf best (cdr pair) best-len (length prefix))))))))

(defun ctx-model-window (model)
  "当前模型的上下文窗口：先查官方 /models 缓存（过期则刷新一次），再查静态兜底表。"
  (when (and (stringp model) (plusp (length model)))
    (or (gethash model *ctx-model-window-cache*)
        (progn
          (when (ctx-model-metadata-stale-p)
            (ignore-errors (ctx-fetch-model-metadata)))
          (or (gethash model *ctx-model-window-cache*)
              (ctx-model-window-static model))))))

;;; 注意：ctx-window 只服务于 CLI 状态栏展示。
;;; Agent 循环里的压缩、截断、重试、轮数控制都不读取它，
;;; 所以即使某个数值不准，也不会引起误压缩或误限流。

(defun ctx-window ()
  "当前模型的最大上下文（tokens），取值顺序：
    1. MYAGENT_CONTEXT_WINDOW（.env 或系统环境变量）；
    2. *ctx-window-tokens* 程序内覆盖；
    3. 官方 /models 返回的 context_window（缓存 1 小时）；
    4. *model-context-windows* 静态兜底表。
    都不命中返回 nil，状态栏只显示绝对 token 数，不编造上限。"
  (or (let ((v (and (fboundp 'get-env)
                    (ignore-errors (get-env "MYAGENT_CONTEXT_WINDOW")))))
        (and v (ignore-errors (parse-integer v))))
      *ctx-window-tokens*
      (ctx-model-window (ctx-current-model))))

(defun ctx-kfmt (n)
  "把 token 数格式化为 950 / 2.9K / 128K / 1.0M。"
  (let ((n (round (or n 0))))
    (cond ((< n 1000) (format nil "~D" n))
          ((< n 10000) (format nil "~,1FK" (/ n 1000.0)))
          ((< n 1000000) (format nil "~DK" (round (/ n 1000))))
          ((< n 10000000) (format nil "~,1FM" (/ n 1000000.0)))
          (t (format nil "~DM" (round (/ n 1000000)))))))

(defun ctx-pct (part total)
  (cond ((or (null total) (<= total 0)) 0)
        ((and (> part 0) (< (/ (float part 1.0) total) 0.01)) 1)
        (t (round (* 100.0 (/ (float part 1.0) total))))))

(defun ctx-status-line (&optional messages)
  "生成底部状态栏：本轮 DeepSeek 缓存命中率 + 当前上下文使用占比（并附会话均值）。
   无数据时返回 nil。messages 仅在缺用量数据时用于估算上下文规模。"
  (let* ((run-total (+ *ctx-run-cache-hit* *ctx-run-cache-miss*))
         (use-run (plusp run-total))
         (sess-hit *ctx-session-cache-hit*)
         (sess-miss *ctx-session-cache-miss*)
         (sess-total (+ sess-hit sess-miss))
         (hit (if use-run *ctx-run-cache-hit* (+ sess-hit *ctx-run-cache-hit*)))
         (miss (if use-run *ctx-run-cache-miss* (+ sess-miss *ctx-run-cache-miss*)))
         (total (+ hit miss))
         (prompt-tok (cond ((plusp *ctx-last-prompt-tokens*) *ctx-last-prompt-tokens*)
                           ((and messages (> (length messages) 0))
                            (ctx-tokens (ctx-messages-chars messages)))
                           (t 0)))
         (parts nil))
    (when (plusp total)
      (push (format nil "~A缓存命中 ~D% (~A/~A)"
                    (if use-run "本轮" "")
                    (ctx-pct hit total) (ctx-kfmt hit) (ctx-kfmt total))
            parts))
    (let ((win (ctx-window)))
      (when (plusp prompt-tok)
        (push (if (and win (plusp win))
                  (format nil "~@[~A ~]上下文 ~D% (~A/~A)"
                          (ctx-current-model) (ctx-pct prompt-tok win)
                          (ctx-kfmt prompt-tok) (ctx-kfmt win))
                  (format nil "~@[~A ~]上下文 ~A tokens（上限未知）" (ctx-current-model) (ctx-kfmt prompt-tok)))
              parts)))
    (when (and use-run (plusp sess-total))
      (push (format nil "会话均 ~D%" (ctx-pct sess-hit sess-total)) parts))
    (when parts
      (format nil "~{~A~^  ·  ~}" (nreverse parts)))))

(defun ctx-status-render (&optional messages)
  "返回带颜色的状态栏文本；无数据时返回 nil。占用越高颜色越警示。"
  (let ((line (ctx-status-line messages)))
    (when line
      (let* ((tok *ctx-last-prompt-tokens*)
             (win (ctx-window))
             (ratio (and win (plusp win) (plusp tok)
                         (/ tok (float win 1.0)))))
        (cond ((and ratio (>= ratio 0.80)) (ui-colorize "1;31" line))
              ((and ratio (>= ratio 0.50)) (ui-colorize "1;33" line))
              (t (ui-dim line)))))))

(defvar *cli-last-print-source* nil
  "最近一次终端打印的来源：:status 表示刚打印过底部状态栏，供自省状态灯吸附到该行最右侧。")

(defvar *cli-status-line-width* 0
  "最近一次底部状态栏的显示宽度（列）。")

(defun ctx-status-print (&optional messages)
  "在 CLI 底部打印一行状态栏（无数据时不打印）。"
  (let ((line (ctx-status-render messages)))
    (when line
      (setf *cli-last-print-source* :status
            *cli-status-line-width* (display-width* line))
      (format t "~A~%" line)
      (finish-output)))
  nil)

(defun ctx-reset-session-stats ()
  "清空会话级统计（/clear 时调用）。"
  (setf *ctx-session-cache-hit* 0
        *ctx-session-cache-miss* 0
        *ctx-session-requests* 0
        *ctx-last-prompt-tokens* 0
        *ctx-last-prompt-chars* 0
        *ctx-run-cache-hit* 0
        *ctx-run-cache-miss* 0
        *ctx-compactions* 0
        *ctx-chars-after-compact* 0)
  nil)


