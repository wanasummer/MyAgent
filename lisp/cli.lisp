;;;; lisp/cli.lisp
;;;; 控制台交互式 CLI 对话界面（含 /model DeepSeek 配置器 + 原生 Lisp S-表达式直通热求值）

(in-package :cl-user)

(defvar *session-history* nil
  "当前 CLI 会话的消息历史（使用 defvar 以在热重载时保留对话上下文）。")

(defvar *session-total-tokens* 0
  "当前 CLI 会话累计消耗的总 token 数。")

(defun print-cli-banner (config)
  (format t "~%╭──────────────────────────────────────────────────────────────╮~%")
  (format t "│  λ MyAgent (Common Lisp / SBCL ~A)                       │~%"
          (lisp-implementation-version))
  (format t "│  🔥 DeepSeek 驱动 · 实时热重载 & S-表达式自我迭代（免重启）   │~%")
  (format t "╰──────────────────────────────────────────────────────────────╯~%")
  (format t "  已加载工具 (~D): ~{~A~^, ~}~%"
          (length *tool-names-order*)
          *tool-names-order*)
  (format t "  快捷指令: /model 配置Key | /tools 工具 | /md 渲染 | /reload 热重载 | /clear 清空 | /exit 退出~%")
  (format t "  Lisp 直通: 输入以 ',' 开头的表达式（如 ,(1+ 2)）可直接求值 Common Lisp 代码~%~%")
  (when (zerop (length (llm-config-api-key config)))
    (format t "  ⚠️ 尚未配置 DeepSeek API Key，请先输入 /model 填入 Key！~%~%"))
  (finish-output))

(defun print-cli-help ()
  (format t "~%📖 可用命令：~%")
  (format t "  /model                    — 配置 DeepSeek API Key~%")
  (format t "  /model <sk-xxx>           — 快捷设置 DeepSeek API Key（模型默认 deepseek-flash）~%")
  (format t "  /tools                    — 查看当前内存中已注册的所有工具（含动态新增工具）~%")
  (format t "  /reload                   — 立即重新热加载全部 lisp/*.lisp 核心模块（保留对话历史）~%")
  (format t "  /eval <expr> 或 ,<expr>   — 直接在当前 SBCL 镜像中求值 Common Lisp 表达式~%")
  (format t "  /clear                    — 清空当前会话历史~%")
  (format t "  /md [on|off]              — 开关 Markdown 彩色渲染（默认自动检测终端）~%")
  (format t "  /help                     — 显示此帮助信息~%")
  (format t "  /exit 或 /quit            — 退出程序~%~%")
  (finish-output))

(defun split-by-spaces (str)
  "按空白字符切分字符串，返回非空子串列表。"
  (let ((tokens nil)
        (start nil)
        (len (length str)))
    (dotimes (i len)
      (let ((ch (char str i)))
        (if (member ch '(#\Space #\Tab))
            (when start
              (push (subseq str start i) tokens)
              (setf start nil))
            (unless start
              (setf start i)))))
    (when start
      (push (subseq str start len) tokens))
    (nreverse tokens)))

(defun handle-model-command (trimmed)
  "处理 /model 命令：仅配置 DeepSeek API Key（模型固定使用默认 deepseek-flash）。"
  (let* ((parts (split-by-spaces trimmed))
         (args (rest parts)))
    (cond
      ;; 1. 无参数：交互式输入 API Key
      ((null args)
       (let ((current (resolve-llm-config :allow-empty-key t)))
         (format t "~%⚙️  DeepSeek API Key 配置 (~A)~%" (get-myagent-config-path))
         (format t "  请输入 DeepSeek API Key (直接回车保持当前 Key): ")
         (finish-output)
         (let* ((key-in (read-line *standard-input* nil ""))
                (new-key (trim-whitespace key-in)))
           (save-deepseek-config
            :api-key (if (> (length new-key) 0) new-key (llm-config-api-key current))
            :model *deepseek-default-model*
            :base-url *deepseek-default-base-url*)
           (format t "~%  ✅ DeepSeek 配置已保存并立即生效！~%~%")
           (finish-output))))

      ;; 2. 单参数：/model <sk-xxx>
      ((= (length args) 1)
       (let ((arg1 (first args)))
         (if (or (and (>= (length arg1) 3) (string-equal "sk-" (subseq arg1 0 3)))
                 (> (length arg1) 24))
             (progn
               (save-deepseek-config
                :api-key arg1
                :model *deepseek-default-model*
                :base-url *deepseek-default-base-url*)
               (format t "~%  ✅ DeepSeek API Key 已更新并保存！~%~%"))
             (format t "~%  ⚠️ 参数不是有效的 API Key。用法：/model <sk-xxx>，或直接输入 /model 进入交互配置。~%~%"))
         (finish-output)))

      ;; 3. 多余参数：提示用法（不再支持切换模型）
      (t
       (format t "~%  ⚠️ /model 现在只用于配置 API Key。用法：/model 或 /model <sk-xxx>~%~%")
       (finish-output)))))

(defun sexp-complete-p (str)
  "检查字符串中的括号是否已闭合（忽略字符串字面量与注释中的括号）。"
  (let ((depth 0)
        (in-string nil)
        (escaped nil)
        (in-comment nil))
    (loop for ch across str
          do (cond
               (in-comment
                (when (char= ch #\Newline)
                  (setf in-comment nil)))
               (escaped
                (setf escaped nil))
               (in-string
                (cond
                  ((char= ch #\\) (setf escaped t))
                  ((char= ch #\") (setf in-string nil))))
               (t
                (cond
                  ((char= ch #\;) (setf in-comment t))
                  ((char= ch #\") (setf in-string t))
                  ((char= ch #\() (incf depth))
                  ((char= ch #\)) (decf depth))))))
    (and (not in-string) (<= depth 0))))

(defun read-cli-input ()
  "读取用户输入行；若是以 ',' 或 '/eval ' 开头的多行 S-表达式，自动续行读取直到括号闭合。"
  (let ((first-line (read-line *standard-input* nil :eof)))
    (when (eq first-line :eof)
      (return-from read-cli-input :eof))
    (let ((trimmed (trim-whitespace first-line)))
      (if (or (and (>= (length trimmed) 1) (char= (char trimmed 0) #\,))
              (and (>= (length trimmed) 6) (string-equal "/eval " (subseq trimmed 0 6))))
          (let ((acc first-line))
            (loop until (sexp-complete-p acc)
                  for next-line = (read-line *standard-input* nil :eof)
                  until (eq next-line :eof)
                  do (setf acc (format nil "~A~%~A" acc next-line)))
            acc)
          first-line))))

(defun handle-slash-command (input)
  "处理 CLI 斜杠指令或逗号 Lisp 求值指令。若已处理则返回 :handled，退出返回 :exit，否则返回 nil。"
  (let ((trimmed (trim-whitespace input)))
    (cond
      ((or (string-equal trimmed "/exit")
           (string-equal trimmed "/quit")
           (string-equal trimmed "exit")
           (string-equal trimmed "quit"))
       (progn (format t "~%👋 再见！~%") (finish-output))
       :exit)

      ((string-equal trimmed "/help")
       (print-cli-help)
       :handled)

      ((or (string-equal trimmed "/model")
           (and (> (length trimmed) 7)
                (string-equal "/model " (subseq trimmed 0 7))))
       (handle-model-command trimmed)
       :handled)

       ((or (string-equal trimmed "/md")
            (and (> (length trimmed) 4)
                 (string-equal "/md " (subseq trimmed 0 4))))
        (let ((arg (trim-whitespace (subseq trimmed 3))))
          (cond
            ((string-equal arg "off")
             (setf *md-color-mode* nil)
             (format t "  🎨 Markdown 彩色渲染已关闭（纯文本模式）。~%~%"))
            ((string-equal arg "on")
             (setf *md-color-mode* t)
             (format t "  🎨 Markdown 彩色渲染已强制开启。~%~%"))
            (t
             (format t "  🎨 Markdown 渲染：~A（用法：/md on | /md off）~%~%"
                     (cond ((eq *md-color-mode* t) "已强制开启")
                           ((null *md-color-mode*) "已关闭")
                           (t "自动检测")))))
          (finish-output)
          :handled))

      ((string-equal trimmed "/clear")
       (setf *session-history* nil)
       (format t "  🧹 会话历史已清空。~%~%")
       :handled)

      ((string-equal trimmed "/tools")
       (format t "~%🔧 当前已注册工具 (~D 个)：~%" (length *tool-names-order*))
       (dolist (name *tool-names-order*)
         (let ((t-entry (gethash name *tool-registry*)))
           (when t-entry
             (format t "  • ~A — ~A~%"
                     name
                     (registered-tool-description t-entry)))))
       (terpri)
       (finish-output)
       :handled)

      ((string-equal trimmed "/reload")
       (dolist (f *core-lisp-files*)
         (hot-reload-lisp-file f))
       (format t "  ✅ 全部核心模块已热重载完成！~%~%")
       (finish-output)
       :handled)

      ((or (and (>= (length trimmed) 1) (char= (char trimmed 0) #\,))
           (and (>= (length trimmed) 6) (string-equal "/eval " (subseq trimmed 0 6))))
       (let* ((code (if (char= (char trimmed 0) #\,)
                        (subseq trimmed 1)
                        (subseq trimmed 6)))
              (res (eval-lisp-string code)))
         (when (and (stringp (jget res "stdout"))
                    (> (length (jget res "stdout")) 0))
           (format t "~A" (jget res "stdout")))
         (if (jtrue-p (jget res "success"))
             (format t "  ⇒ ~A~%~%" (jget res "result"))
             (format t "  ❌ 求值错误: ~A~%~%" (jget res "error")))
         (finish-output)
         :handled))

      (t nil))))

(defun start-cli ()
  "启动控制台交互式对话主循环。"
  (let ((config (resolve-llm-config :allow-empty-key t)))
    (print-cli-banner config)
    (loop for input-count from 1
          do (format t "You > ")
      (finish-output)
      (let ((line (handler-case (read-cli-input)
                    (end-of-file () :eof)
                    (error (e)
                      (format *error-output* "~%读取输入错误: ~A~%" e)
                      ""))))
        (when (eq line :eof)
          (if (= input-count 1)
              (progn
                (format t "~%⚠️ 标准输入(stdin)在启动时就是 EOF / 已被关闭。~%   说明程序不是在交互式终端里启动的（可能被重定向、管道，或被 chcp 之类命令吞掉了 stdin）。~%   请在 cmd 或 PowerShell 窗口运行 start.bat，或使用单次模式：~%   sbcl --load run.lisp --prompt 你好~%")
                (finish-output)
                (return :eof-at-startup))
              (progn
                (format t "~%👋 收到 EOF，退出。~%")
                (finish-output)
                (return))))
        (let ((trimmed (trim-whitespace line)))
          (when (> (length trimmed) 0)
            (let ((cmd-status (funcall 'handle-slash-command trimmed)))
              (cond
                ((eq cmd-status :exit) (return))
                ((eq cmd-status :handled) nil)
                (t
                 (handler-case
                     ;; 通过符号 funcall 调用 'run-agent，确保热重载 agent-loop.lisp 后立即调用新版！
                     (let* ((result (funcall 'run-agent trimmed *session-history*))
                            (answer (getf result :answer))
                            (new-history (getf result :history))
                            (in-tok (or (getf result :input-tokens) 0))
                            (out-tok (or (getf result :output-tokens) 0)))
                       (setf *session-history* new-history)
                       (incf *session-total-tokens* (+ in-tok out-tok))
                        (format t "~%Agent >~%~A~%~%"
                                (if (fboundp 'render-markdown)
                                    (funcall 'render-markdown answer)
                                    answer))
                       (finish-output))
                   (error (e)
                     (format *error-output* "~%  ❌ 执行异常: ~A~%~%" e)
                     (finish-output))))))))))))
