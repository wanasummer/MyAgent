;;;; run.lisp
;;;; MyAgent Common Lisp (SBCL) 启动入口
;;;;
;;;; 用法：
;;;;   sbcl --noinform --load run.lisp              — 进入交互式 CLI 对话模式
;;;;   sbcl --script run.lisp --prompt "你好"       — 单次指令执行模式
;;;;   .\start.bat                                  — Windows 一键启动

(in-package :cl-user)

#+sbcl
(progn
  (setf sb-impl::*default-external-format* :utf-8)
  (setf sb-ext:*muffled-warnings* 'style-warning))

(require :asdf)

(defparameter *startup-modules*
  '("lisp/json.lisp"
    "lisp/config.lisp"
    "lisp/ui.lisp"
    "lisp/file-utils.lisp"
    "lisp/markdown.lisp"
    "lisp/llm-client.lisp"
    "lisp/cancel.lisp"
    ;; 安全热重载引擎必须在 tools.lisp 之前加载：
    ;; 这样即使 tools.lisp 被改坏，回滚引擎依然可用。
    "lisp/reload-engine.lisp"
    "lisp/tools.lisp"
    "lisp/agent-loop.lisp"
    "lisp/context-manager.lisp"
    "lisp/cli.lisp")
  "启动时按顺序加载的核心模块。")

(defun startup-base-dir ()
  "返回 run.lisp 所在目录。"
  (uiop:pathname-directory-pathname
   (or *load-truename* *compile-file-truename* (uiop:getcwd))))

(defun load-core-modules ()
  "按顺序加载全部核心模块，并初始化热重载快照。"
  (let ((base-dir (startup-base-dir)))
    (dolist (m *startup-modules*)
      (load (merge-pathnames m base-dir) :external-format :utf-8))
    (when (fboundp 'seed-lisp-backups)
      (seed-lisp-backups))
    (when (fboundp 'check-and-hot-reload-modified-files)
      (check-and-hot-reload-modified-files))))

(defun main ()
  (let* ((args (uiop:command-line-arguments))
         (prompt-pos (or (position "--prompt" args :test #'string=)
                         (position "-p" args :test #'string=)))
         (eval-pos (or (position "--eval-lisp" args :test #'string=)
                       (position "-e" args :test #'string=))))
    (cond
      (eval-pos
       (let* ((code (nth (1+ eval-pos) args))
              (res (eval-lisp-string (or code "nil"))))
         (format t "~A~%" (json-encode res))
         :ok))
      (prompt-pos
       (let* ((prompt (nth (1+ prompt-pos) args))
              (res (run-agent prompt nil)))
         (format t "~%Agent >~%~A~%" (getf res :answer))
         (when (fboundp 'ctx-status-print)
           (funcall 'ctx-status-print (getf res :history)))
         :ok))
      (t
       (start-cli)))))

(defun report-fatal-error (e)
  "以可读方式报告致命错误，避免直接掉进裸调试器且窗口一闪而过。"
  (format *error-output* "~%[X] MyAgent 异常终止：~A~%" e)
  (ignore-errors (sb-debug:print-backtrace :count 20 :stream *error-output*))
  (finish-output *error-output*)
  (finish-output))

;;; 只有「全新启动」时才执行下面的启动流程；
;;; 如果本文件被 write_file / hot-reload 加载进正在运行的镜像，则自动跳过，
;;; 避免误触 (main) 或 (uiop:quit) 把当前运行的 Agent 进程杀掉。
(if (and (fboundp 'run-agent) (boundp '*tool-registry*))
    (format t "  ~A run.lisp 已在运行中的镜像内加载，跳过启动流程。~%" (ui-tag-info "提示"))
    (let ((result nil))
      (handler-case
          (progn
            (load-core-modules)
            (setf result (main)))
        (error (e)
          (report-fatal-error e)
          (uiop:quit 1)))
      (finish-output)
      ;; 退出码 3 = 启动时即遇到 stdin EOF（start.bat 会 pause，方便看到提示）
      (uiop:quit (if (eq result :eof-at-startup) 3 0))))
