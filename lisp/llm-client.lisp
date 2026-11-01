;;;; lisp/llm-client.lisp
;;;; DeepSeek 专用 LLM 客户端 (Anthropic Messages 兼容协议)
;;;; 使用原生 curl 进行二进制 UTF-8 临时文件传输，避免命令行长度与编码问题。
;;;; 交互式控制台下默认走 SSE 流式输出：边生成边显示，工具调用块增量拼接。

(in-package :cl-user)

(defparameter *temp-counter* 0)

(defun make-temp-filepath (prefix)
  "生成唯一的临时文件路径。"
  (incf *temp-counter*)
  (let ((tmp-dir (namestring (uiop:temporary-directory))))
    ;; 中断后的后台请求可能与新请求并行，加入随机数避免临时文件名冲突
    (format nil "~A~A-~D-~D-~D.json"
            (normalize-slashes tmp-dir)
            prefix
            (get-universal-time)
            (random 1000000)
            *temp-counter*)))

(defun curl-executable ()
  "返回 curl 可执行文件名（Windows 用 curl.exe，其它平台用 curl），可用 MYAGENT_CURL 覆盖。"
  (or (uiop:getenv "MYAGENT_CURL")
      #+win32 "curl.exe"
      #-win32 "curl"))

(defparameter *http-connect-timeout* "10"
  "建立连接的超时秒数（避免网络异常时长时间静默）。")

(defparameter *http-max-time* "180"
  "单次请求总超时秒数；用户也可以随时按 ESC 中断。")

;;; ── 流式状态 ─────────────────────────────────────────

(defparameter *stream-enabled* t
  "是否启用流式输出。仅交互式控制台生效，非交互场景（--prompt 等）自动回退为整包响应。")

(defvar *stream-output-started* nil
  "本次请求是否已经输出过正文增量（供等待提示与最终回显判断）。")

(defvar *active-stream-proc* nil
  "当前正在运行的流式 curl 子进程；按 ESC 时主线程可直接终止它以立即唤醒 read-line。")

(defun abort-active-llm-stream ()
  "立即终止当前正在执行的流式 curl 子进程（供 ESC 中断调用）。"
  (let ((p *active-stream-proc*))
    (when (and p (ignore-errors (uiop:process-alive-p p)))
      (ignore-errors (uiop:terminate-process p :force t))))
  t)

(defun stream-mode-active-p ()
  "当前是否应该走流式输出。"
  (and *stream-enabled*
       (boundp '*raw-console-active*)
       (symbol-value '*raw-console-active*)))

(defun stream-output-started-p ()
  "本次请求是否已经打印过正文（供 run-agent 判断是否还需要回显最终答案）。"
  (and *stream-output-started* t))

(defun request-cancelled-p ()
  "用户是否已请求中断当前任务。"
  (and (fboundp 'agent-cancel-requested-p)
       (ignore-errors (funcall 'agent-cancel-requested-p))))

;;; ── 非流式请求（回退路径） ───────────────────────────

;;; ── HTTP 失败重试 ───────────────────────────────────

(define-condition http-retryable-error (error)
  ((message :initarg :message :initform "HTTP 请求失败" :reader http-retryable-message)
   (status :initarg :status :initform nil :reader http-retryable-status))
  (:report (lambda (c s) (format s "~A" (http-retryable-message c)))))

(defparameter *http-max-attempts* 3
  "单次请求最多尝试次数（含首次）。可用环境变量 MYAGENT_HTTP_RETRIES 覆盖。")

(defparameter *http-retry-base-delay* 1.0
  "首次重试前的等待秒数，之后按 2 倍指数退避（1s / 2s / 4s ...）。")

(defparameter *http-retry-max-delay* 8.0
  "单次重试等待上限（秒）。")

(defun http-max-attempts-value ()
  "实际使用的最大尝试次数：MYAGENT_HTTP_RETRIES 优先。"
  (or (let ((v (and (fboundp 'get-env)
                    (ignore-errors (get-env "MYAGENT_HTTP_RETRIES")))))
        (and v (let ((n (ignore-errors (parse-integer v))))
                 (and n (plusp n) n))))
      *http-max-attempts*))

(defun retryable-http-status-p (code)
  "临时性故障（超时 / 限流 / 网关与 5xx）值得重试；
400 / 401 / 403 这类配置或权限错误重试也不会好。"
  (and (integerp code)
       (member code '(408 425 429 500 502 503 504 520 522 524 529) :test #'=)
       t))

(defun http-retry-delay (attempt)
  "第 ATTEMPT 次失败后应等待的秒数（指数退避 + 上限）。"
  (min *http-retry-max-delay*
       (* *http-retry-base-delay* (expt 2 (max 0 (1- attempt))))))

(defun do-with-http-retry (label thunk &key no-retry-p)
  "执行 THUNK；捕获 http-retryable-error 后按指数退避重试。
NO-RETRY-P 返回真时立即放弃重试（例如流式响应已经输出过内容，重试会重复显示）。"
  (loop with max = (http-max-attempts-value)
        for attempt from 1
        do (handler-case
               (return (funcall thunk))
             (http-retryable-error (e)
               (when (or (>= attempt max)
                         (request-cancelled-p)
                         (and no-retry-p (funcall no-retry-p)))
                 (error "~A失败（已尝试 ~D 次）：~A"
                        label attempt (http-retryable-message e)))
               (let ((d (http-retry-delay attempt)))
                 (format t "  ~A ~A 第 ~D/~D 次失败：~A，~,1Fs 后重试~%"
                         (ui-tag-warn "重试") label attempt max
                         (http-retryable-message e) d)
                 (finish-output)
                 (sleep d))))))

(defun http-post-json (url headers body-obj)
  "通过 curl.exe 发送 POST JSON 请求，返回解析后的 JSON 对象。"
  (let ((req-file (make-temp-filepath "myagent-req"))
        (resp-file (make-temp-filepath "myagent-resp")))
    (unwind-protect
         (progn
           ;; 1. 将 JSON 写入 UTF-8 临时文件
           (with-open-file (out (native-file-pathname req-file)
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create
                                :external-format :utf-8)
             (write-json-value body-obj out))
           ;; 2. 组装 curl 命令参数
           (let ((cmd (list (curl-executable) "-s" "-S" "-X" "POST" url
                            "--connect-timeout" *http-connect-timeout*
                            "--max-time" *http-max-time*)))
             (dolist (h headers)
               (setf cmd (append cmd (list "-H" h))))
             (setf cmd (append cmd
                               (list "--data-binary" (format nil "@~A" (uiop:native-namestring (native-file-pathname req-file)))
                                     "-o" (uiop:native-namestring (native-file-pathname resp-file))
                                     "-w" "%{http_code}")))
             (multiple-value-bind (stdout stderr exit-code)
                 (uiop:run-program cmd
                                   :output :string
                                   :error-output :string
                                   :ignore-error-status t)
                              (unless (zerop exit-code)
                 (error 'http-retryable-error
                        :message (format nil "curl exit ~D: ~A" exit-code
                                         (subseq stderr 0 (min 160 (length stderr))))))
               (let* ((status-code (or (ignore-errors (parse-integer (trim-whitespace stdout))) 0))
                      (resp-text (if (uiop:file-exists-p (native-file-pathname resp-file))
                                     (uiop:read-file-string (native-file-pathname resp-file) :external-format :utf-8)
                                     "")))
                 (when (or (< status-code 200) (>= status-code 300))
                   (if (retryable-http-status-p status-code)
                       (error 'http-retryable-error
                              :status status-code
                              :message (format nil "HTTP ~D: ~A" status-code
                                               (subseq resp-text 0 (min 160 (length resp-text)))))
                       (error "DeepSeek API Error ~D (可通过 /model 重新配置 Key 或模型): ~A" status-code resp-text)))
                 (json-decode resp-text)))))
      ;; 清理临时文件
      (ignore-errors (when (uiop:file-exists-p (native-file-pathname req-file))
                       (delete-file (native-file-pathname req-file))))
      (ignore-errors (when (uiop:file-exists-p (native-file-pathname resp-file))
                       (delete-file (native-file-pathname resp-file)))))))

(defparameter *default-max-output-tokens* 65536
  "单次响应的最大输出 tokens（上限，不是固定生成量）。可用 MYAGENT_MAX_TOKENS 覆盖。
    deepseek-flash / deepseek-v4-pro 官方 max_output_tokens = 393216；默认 65536 兼顾长文件写入与成本。")

(defun effective-max-output-tokens ()
  "实际发送给 API 的 max_tokens：MYAGENT_MAX_TOKENS（.env 或系统环境变量）优先。"
  (or (let ((v (and (fboundp 'get-env)
                    (ignore-errors (get-env "MYAGENT_MAX_TOKENS")))))
        (and v (let ((n (ignore-errors (parse-integer v))))
                 (and n (plusp n) n))))
      *default-max-output-tokens*))

(defun send-deepseek-request (config system messages tools)
  "向 DeepSeek Anthropic 兼容端点发送非流式请求。"
  (let* ((url (format nil "~A/v1/messages" (llm-config-base-url config)))
         (headers (list "Content-Type: application/json"
                        (format nil "x-api-key: ~A" (llm-config-api-key config))
                        "anthropic-version: 2023-06-01"))
         (body (jobj "model" (llm-config-model config)
                     "max_tokens" (effective-max-output-tokens)
                     "system" system
                     "messages" messages
                     "tools" tools)))
    (http-post-json url headers body)))

;;; ── SSE 流式请求 ─────────────────────────────────────

(defun sse-json-payload (line)
  "从 `data: {...}` 行提取 JSON 字符串；不是 data 行时返回 nil。"
  (when (and (> (length line) 5)
             (string-equal "data:" (subseq line 0 5)))
    (string-left-trim '(#\Space #\Tab) (subseq line 5))))

(defun assemble-stream-blocks (blocks)
  "把流式累积的块按 index 顺序还原为标准 content 数组。"
  (let ((out nil)
        (keys (loop for k being the hash-keys of blocks collect k)))
    (dolist (idx (sort keys #'<))
      (let* ((b (gethash idx blocks))
             (ty (jget b "type")))
        (cond
          ((equal ty "text")
           (let ((txt (jget b "text")))
             (when (and (stringp txt) (plusp (length txt)))
               (push (jobj "type" "text" "text" txt) out))))
          ((equal ty "thinking")
           (push (jobj "type" "thinking"
                       "thinking" (or (jget b "thinking") "")
                       "signature" (or (jget b "signature") ""))
                 out))
          ((equal ty "tool_use")
           (push (jobj "type" "tool_use"
                       "id" (or (jget b "id") "")
                       "name" (or (jget b "name") "")
                       "input" (or (jget b "input") (jobj)))
                 out)))))
    (nreverse out)))

(defun drain-stream-string (stream)
  "读完一个字符流，返回其全部文本（读不到时返回空串）。"
  (if (null stream)
      ""
      (let ((out (make-string-output-stream)))
        (handler-case
            (loop for line = (read-line stream nil nil)
                  while line
                  do (write-string line out) (terpri out))
          (error () nil))
        (get-output-stream-string out))))

(defun send-deepseek-request-stream (config system messages tools)
  "以 SSE 方式请求模型：正文增量实时打印，工具调用参数增量拼接，
返回与非流式完全一致的响应对象（content / usage / stop_reason）。
被用户中断时返回 NIL。"
  (let* ((url (format nil "~A/v1/messages" (llm-config-base-url config)))
         (headers (list "Content-Type: application/json"
                        (format nil "x-api-key: ~A" (llm-config-api-key config))
                        "anthropic-version: 2023-06-01"))
         (body (jobj "model" (llm-config-model config)
                     "max_tokens" (effective-max-output-tokens)
                     "stream" t
                     "system" system
                     "messages" messages
                     "tools" tools))
         (req-file (make-temp-filepath "myagent-stream-req"))
         (blocks (make-hash-table :test 'eql))
         (in-tokens 0)
         (out-tokens 0)
         (stop-reason nil)
         (cancelled nil)
         (text-renderer nil)
         (proc nil))
    (labels ((emit-text (txt)
             "正文增量：立即打印；已取消则只累积不显示。"
             (setf *stream-output-started* t)
             (unless (request-cancelled-p)
               (when (and (null text-renderer) (fboundp 'md-stream-start))
                 (setf text-renderer (funcall 'md-stream-start)))
               (if (and text-renderer (fboundp 'md-stream-feed))
                   (funcall 'md-stream-feed text-renderer txt)
                   (progn (write-string txt) (finish-output)))))
           (handle-event (obj)
             (let ((etype (jget obj "type")))
               (cond
                 ((equal etype "message_start")
                  (let* ((msg (jget obj "message"))
                         (u (jget msg "usage")))
                    (when (hash-table-p u)
                      (setf in-tokens (or (jget u "input_tokens") 0)))))

                 ((equal etype "content_block_start")
                  (let* ((idx (jget obj "index"))
                         (cb (jget obj "content_block"))
                         (ty (and (hash-table-p cb) (jget cb "type")))
                         (b (jobj "type" ty)))
                    (cond
                      ((equal ty "text")
                       (setf (jget b "text") (or (jget cb "text") "")))
                      ((equal ty "thinking")
                       (setf (jget b "thinking") (or (jget cb "thinking") "")
                             (jget b "signature") (or (jget cb "signature") "")))
                      ((equal ty "tool_use")
                       (setf (jget b "id") (or (jget cb "id") "")
                             (jget b "name") (or (jget cb "name") "")
                             (jget b "_json") "")))
                    (setf (gethash idx blocks) b)))

                 ((equal etype "content_block_delta")
                  (let* ((idx (jget obj "index"))
                         (b (gethash idx blocks))
                         (d (jget obj "delta"))
                         (dt (and (hash-table-p d) (jget d "type"))))
                    (when b
                      (cond
                        ((equal dt "text_delta")
                         (let ((txt (jget d "text")))
                           (when (stringp txt)
                             (setf (jget b "text")
                                   (concatenate 'string (or (jget b "text") "") txt))
                             (emit-text txt))))
                        ((equal dt "thinking_delta")
                         (let ((tx (jget d "thinking")))
                           (when (stringp tx)
                             (setf (jget b "thinking")
                                   (concatenate 'string (or (jget b "thinking") "") tx)))))
                        ((equal dt "signature_delta")
                         (let ((sg (jget d "signature")))
                           (when (stringp sg)
                             (setf (jget b "signature")
                                   (concatenate 'string (or (jget b "signature") "") sg)))))
                        ((equal dt "input_json_delta")
                         (let ((pj (jget d "partial_json")))
                           (when (stringp pj)
                             (setf (jget b "_json")
                                   (concatenate 'string (or (jget b "_json") "") pj)))))))))

                 ((equal etype "content_block_stop")
                  (when (and text-renderer (fboundp 'md-stream-finish))
                    (funcall 'md-stream-finish text-renderer)
                    (setf text-renderer nil))
                  (let ((b (gethash (jget obj "index") blocks)))
                    (when (and b (equal (jget b "type") "tool_use"))
                      (let ((raw-json (jget b "_json")))
                        (setf (jget b "input")
                              (if (and raw-json (plusp (length raw-json)))
                                  (or (ignore-errors (json-decode raw-json)) (jobj))
                                  (jobj)))))))

                 ((equal etype "message_delta")
                  (let ((d (jget obj "delta"))
                        (u (jget obj "usage")))
                    (when (hash-table-p d)
                      (let ((sr (jget d "stop_reason")))
                        (when (stringp sr) (setf stop-reason sr))))
                    (when (hash-table-p u)
                      (let ((o (jget u "output_tokens")))
                        (when (numberp o) (setf out-tokens o))))))))))
      (unwind-protect
           (progn
             (with-open-file (out (native-file-pathname req-file)
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
               (write-json-value body out))
             (setf *stream-output-started* nil)
             (setf proc
                   (uiop:launch-program
                    (append (list (curl-executable) "-s" "-S" "-N" "-X" "POST" url
                                  "--connect-timeout" *http-connect-timeout*
                                  "--max-time" *http-max-time*)
                            (loop for h in headers append (list "-H" h))
                            (list "--data-binary"
                                  (format nil "@~A" (uiop:native-namestring (native-file-pathname req-file)))))
                    :output :stream :error-output :stream))
             (setf *active-stream-proc* proc)
             (let ((stream (uiop:process-info-output proc)))
               (unwind-protect
                    (loop
                      (when (request-cancelled-p)
                        (setf cancelled t)
                        (ignore-errors (uiop:terminate-process proc :force t))
                        (return))
                      (let ((raw (read-line stream nil :eof)))
                        (when (request-cancelled-p)
                          (setf cancelled t)
                          (ignore-errors (uiop:terminate-process proc :force t))
                          (return))
                        (when (eq raw :eof) (return))
                        (let* ((line (string-right-trim '(#\Return) raw))
                               (payload (sse-json-payload line)))
                          (when (and payload (plusp (length payload))
                                     (not (string= payload "[DONE]")))
                            (let ((obj (ignore-errors (json-decode payload))))
                              (when (hash-table-p obj)
                                (handle-event obj)))))))
                 (ignore-errors (close stream))))
             (when (request-cancelled-p)
               (setf cancelled t))
             (let* ((code (ignore-errors (uiop:wait-process proc)))
                    (err (ignore-errors (drain-stream-string
                                         (uiop:process-info-error-output proc)))))
               (when (and text-renderer (fboundp 'md-stream-finish))
                 (funcall 'md-stream-finish text-renderer)
                 (setf text-renderer nil))
               (when *stream-output-started*
                 (format t "~%")
                 (finish-output))
                              (unless (or cancelled (null code) (eql code 0))
                 (error 'http-retryable-error
                        :message (format nil "curl exit ~A: ~A" code (or err "")))))
             (if cancelled
                 nil
                 (jobj "stop_reason" (or stop-reason "end_turn")
                       "usage" (jobj "input_tokens" in-tokens
                                     "output_tokens" out-tokens)
                       "content" (assemble-stream-blocks blocks))))
        (when (eq *active-stream-proc* proc)
          (setf *active-stream-proc* nil))
        (ignore-errors (when (and proc (uiop:process-alive-p proc))
                         (uiop:terminate-process proc :force t)))
        (ignore-errors (when (uiop:file-exists-p (native-file-pathname req-file))
                         (delete-file (native-file-pathname req-file))))))))

(defun chat-with-tools (&key system messages tools)
  "调用当前配置的 DeepSeek 模型；交互式控制台默认使用流式输出。
网络故障、429 限流、5xx 网关错误等临时性失败会自动重试（指数退避，
上限 *http-max-attempts* 次，可用 MYAGENT_HTTP_RETRIES 覆盖）；
一旦流式内容已经开始输出，就不再重试，避免重复显示。"
  (let ((config (resolve-llm-config)))
    (do-with-http-retry
     "LLM 请求"
     (lambda ()
       (setf *stream-output-started* nil)
       (if (stream-mode-active-p)
           (let ((res (send-deepseek-request-stream config system messages tools)))
             (cond
               ((null res) res)
               ((equal (jget res "stop_reason") "cancelled") res)
               ;; 流式一个事件都没收到：多半是网关/限流把错误当普通 JSON 返回，重试通常可恢复
               ((and (null (jget res "content")) (not *stream-output-started*))
                (error 'http-retryable-error
                       :message "流式响应为空（可能被限流或网关错误）"))
               (t res)))
           (send-deepseek-request config system messages tools)))
     :no-retry-p (lambda () *stream-output-started*))))
