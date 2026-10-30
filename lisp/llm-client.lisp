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
                 (error "HTTP 请求失败 (curl exit ~D): ~A" exit-code stderr))
               (let* ((status-code (or (ignore-errors (parse-integer (trim-whitespace stdout))) 0))
                      (resp-text (if (uiop:file-exists-p (native-file-pathname resp-file))
                                     (uiop:read-file-string (native-file-pathname resp-file) :external-format :utf-8)
                                     "")))
                 (when (or (< status-code 200) (>= status-code 300))
                   (error "DeepSeek API Error ~D (可通过 /model 重新配置 Key 或模型): ~A" status-code resp-text))
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
         (proc nil))
    (labels ((emit-text (txt)
             "正文增量：立即打印；已取消则只累积不显示。"
             (setf *stream-output-started* t)
             (unless (request-cancelled-p)
               (write-string txt)
               (finish-output)))
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
             (let ((stream (uiop:process-info-output proc)))
               (unwind-protect
                    (loop
                      (when (request-cancelled-p)
                        (setf cancelled t)
                        (ignore-errors (uiop:terminate-process proc :force t))
                        (return))
                      (let ((raw (read-line stream nil :eof)))
                        (when (eq raw :eof) (return))
                        (let* ((line (string-right-trim '(#\Return) raw))
                               (payload (sse-json-payload line)))
                          (when (and payload (plusp (length payload))
                                     (not (string= payload "[DONE]")))
                            (let ((obj (ignore-errors (json-decode payload))))
                              (when (hash-table-p obj)
                                (handle-event obj)))))))
                 (ignore-errors (close stream))))
             (let* ((code (ignore-errors (uiop:wait-process proc)))
                    (err (ignore-errors (drain-stream-string
                                         (uiop:process-info-error-output proc)))))
               (when *stream-output-started*
                 (format t "~%")
                 (finish-output))
               (unless (or cancelled (null code) (eql code 0))
                 (error "HTTP 请求失败 (curl exit ~A): ~A" code (or err ""))))
             (if cancelled
                 nil
                 (jobj "stop_reason" (or stop-reason "end_turn")
                       "usage" (jobj "input_tokens" in-tokens
                                     "output_tokens" out-tokens)
                       "content" (assemble-stream-blocks blocks))))
        (ignore-errors (when (and proc (uiop:process-alive-p proc))
                         (uiop:terminate-process proc :force t)))
        (ignore-errors (when (uiop:file-exists-p (native-file-pathname req-file))
                         (delete-file (native-file-pathname req-file))))))))

(defun chat-with-tools (&key system messages tools)
  "调用当前配置的 DeepSeek 模型；交互式控制台默认使用流式输出。"
  (let ((config (resolve-llm-config)))
    (if (stream-mode-active-p)
        (or (send-deepseek-request-stream config system messages tools)
            ;; 被中断：返回占位响应，主线程会按 :cancelled 处理并丢弃
            (jobj "content" nil
                  "usage" (jobj "input_tokens" 0 "output_tokens" 0)
                  "stop_reason" "cancelled"))
        (send-deepseek-request config system messages tools))))
