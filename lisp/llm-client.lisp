;;;; lisp/llm-client.lisp
;;;; DeepSeek 专用 LLM 客户端 (Anthropic Messages 兼容协议)
;;;; 使用原生 curl 进行二进制 UTF-8 临时文件传输，避免命令行长度与编码问题。

(in-package :cl-user)

(defparameter *temp-counter* 0)

(defun make-temp-filepath (prefix)
  "生成唯一的临时文件路径。"
  (incf *temp-counter*)
  (let ((tmp-dir (namestring (uiop:temporary-directory))))
    (format nil "~A~A-~D-~D.json"
            (normalize-slashes tmp-dir)
            prefix
            (get-universal-time)
            *temp-counter*)))

(defun curl-executable ()
  "返回 curl 可执行文件名（Windows 用 curl.exe，其它平台用 curl），可用 MYAGENT_CURL 覆盖。"
  (or (uiop:getenv "MYAGENT_CURL")
      #+win32 "curl.exe"
      #-win32 "curl"))

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
                            "--connect-timeout" "30"
                            "--max-time" "300")))
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

(defun send-deepseek-request (config system messages tools)
  "向 DeepSeek Anthropic 兼容端点发送请求。"
  (let* ((url (format nil "~A/v1/messages" (llm-config-base-url config)))
         (headers (list "Content-Type: application/json"
                        (format nil "x-api-key: ~A" (llm-config-api-key config))
                        "anthropic-version: 2023-06-01"))
         (body (jobj "model" (llm-config-model config)
                     "max_tokens" 8192
                     "system" system
                     "messages" messages
                     "tools" tools)))
    (http-post-json url headers body)))

(defun chat-with-tools (&key system messages tools)
  "调用当前配置的 DeepSeek 模型。"
  (let ((config (resolve-llm-config)))
    (send-deepseek-request config system messages tools)))
