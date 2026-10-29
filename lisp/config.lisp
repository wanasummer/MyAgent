;;;; lisp/config.lisp
;;;; DeepSeek 专属配置管理 (.env & ~/.myagent/config 加载与持久化)
;;;; 目前仅支持 DeepSeek 单一提供商

(in-package :cl-user)

(require :asdf)

(defparameter *deepseek-default-base-url* "https://api.deepseek.com/anthropic"
  "DeepSeek Anthropic 兼容接口地址。")

(defparameter *deepseek-default-model* "deepseek-flash"
  "DeepSeek 默认模型名称。")

(defvar *env-overrides* (make-hash-table :test 'equal)
  "从配置文件或运行时 /model 命令加载的配置项。")

(defun trim-whitespace (str)
  (if (stringp str)
      (string-trim '(#\Space #\Tab #\Return #\Newline #\ufeff #\Null) str)
      ""))

(defun strip-surrounding-quotes (str)
  "去掉值两端匹配的引号（单引号或双引号）。"
  (let ((len (length str)))
    (if (and (>= len 2)
             (or (and (char= (char str 0) #\") (char= (char str (1- len)) #\"))
                 (and (char= (char str 0) #\') (char= (char str (1- len)) #\'))))
        (subseq str 1 (1- len))
        str)))

(defun get-user-home-dir ()
  "获取当前用户主目录字符串（不带末尾斜杠）。"
  (let ((env-home (or (uiop:getenv "USERPROFILE")
                      (uiop:getenv "HOME")
                      (namestring (user-homedir-pathname)))))
    (string-right-trim "/\\" env-home)))

(defun get-myagent-config-path ()
  "返回配置文件路径：默认 ~/.myagent/config；可用环境变量 MYAGENT_CONFIG 覆盖。
注意：该文件保存 API Key，切勿提交到仓库。"
  (let ((env (uiop:getenv "MYAGENT_CONFIG")))
    (if (and env (> (length (trim-whitespace env)) 0))
        (resolve-path env)
        (format nil "~A/.myagent/config" (get-user-home-dir)))))

(defun load-dotenv-file (filepath &key (override t))
  "加载指定路径的配置文件到 *env-overrides*。"
  (when (probe-file filepath)
    (with-open-file (in filepath :direction :input :external-format :utf-8 :if-does-not-exist nil)
      (when in
        (loop for raw-line = (read-line in nil nil)
              while raw-line
              for line = (trim-whitespace raw-line)
              do (when (and (> (length line) 0)
                            (not (char= (char line 0) #\#))
                            (not (char= (char line 0) #\<))
                            (null (search "-->" line)))
                   (when (and (> (length line) 7)
                              (string= "export " (subseq line 0 7)))
                     (setf line (trim-whitespace (subseq line 7))))
                   (let ((eq-pos (position #\= line)))
                     (when eq-pos
                       (let ((key (trim-whitespace (subseq line 0 eq-pos)))
                             (val (strip-surrounding-quotes
                                   (trim-whitespace (subseq line (1+ eq-pos))))))
                         (when (and (> (length key) 0)
                                    (or override (null (gethash key *env-overrides*))))
                           (setf (gethash key *env-overrides*) val)))))))))))

(defun get-env (name &optional default)
  "优先从内存 *env-overrides* 获取配置，其次从系统环境变量获取。"
  (let ((val (or (gethash name *env-overrides*)
                 (uiop:getenv name))))
    (if (and val (> (length (trim-whitespace val)) 0))
        (trim-whitespace val)
        default)))

(defvar *config-initialized* nil)

(defun init-env-config (&key (force nil))
  "初始化加载 .env 与 ~/.myagent/config。"
  (when (or force (not *config-initialized*))
    (let* ((cwd (namestring (uiop:getcwd)))
           (local-env (merge-pathnames ".env" cwd))
           (myagent-config (get-myagent-config-path)))
      (load-dotenv-file local-env :override t)
      (load-dotenv-file myagent-config :override t)
      (setf *config-initialized* t))))

(defstruct llm-config
  provider   ; 固定为 :deepseek
  api-key
  base-url
  model)

(defun resolve-llm-config (&key (allow-empty-key nil))
  "解析当前 DeepSeek 配置（支持 DEEPSEEK_API_KEY 或兼容 ANTHROPIC_API_KEY）。"
  (init-env-config)
  (let ((api-key (or (get-env "DEEPSEEK_API_KEY")
                     (get-env "ANTHROPIC_API_KEY")
                     ""))
        (base-url (string-right-trim
                   "/"
                   (or (get-env "DEEPSEEK_BASE_URL")
                       (get-env "ANTHROPIC_BASE_URL")
                       *deepseek-default-base-url*)))
        (model (or (get-env "DEEPSEEK_MODEL")
                   (get-env "ANTHROPIC_MODEL")
                   *deepseek-default-model*)))
    (when (and (not allow-empty-key) (zerop (length api-key)))
      (error "尚未配置 DeepSeek API Key！请在控制台输入 /model 配置你的 DeepSeek Key。"))
    (make-llm-config
     :provider :deepseek
     :api-key api-key
     :base-url base-url
     :model model)))

(defun save-deepseek-config (&key api-key model base-url)
  "更新当前内存中的 DeepSeek 配置并持久化写入 ~/.myagent/config。"
  (init-env-config)
  (let* ((current (resolve-llm-config :allow-empty-key t))
         (final-key (if (and api-key (> (length (trim-whitespace api-key)) 0))
                        (trim-whitespace api-key)
                        (llm-config-api-key current)))
         (final-model (if (and model (> (length (trim-whitespace model)) 0))
                          (trim-whitespace model)
                          (or (llm-config-model current) *deepseek-default-model*)))
         (final-url (if (and base-url (> (length (trim-whitespace base-url)) 0))
                        (string-right-trim "/" (trim-whitespace base-url))
                        (or (llm-config-base-url current) *deepseek-default-base-url*)))
         (cfg-path (get-myagent-config-path))
         (cfg-pn (uiop:parse-native-namestring cfg-path)))
    ;; 更新内存配置（同时同步 DEEPSEEK_* 与 ANTHROPIC_* 键，彻底避免旧配置覆盖）
    (setf (gethash "DEEPSEEK_API_KEY" *env-overrides*) final-key
          (gethash "ANTHROPIC_API_KEY" *env-overrides*) final-key
          (gethash "DEEPSEEK_MODEL" *env-overrides*) final-model
          (gethash "ANTHROPIC_MODEL" *env-overrides*) final-model
          (gethash "DEEPSEEK_BASE_URL" *env-overrides*) final-url
          (gethash "ANTHROPIC_BASE_URL" *env-overrides*) final-url)
    ;; 持久化保存到 ~/.myagent/config
    (ensure-directories-exist cfg-pn)
    (with-open-file (out cfg-pn :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create
                                :external-format :utf-8)
      (format out "# MyAgent DeepSeek 配置文件 (由 /model 自动生成)~%")
      (format out "DEEPSEEK_API_KEY=~A~%" final-key)
      (format out "DEEPSEEK_MODEL=~A~%" final-model)
      (format out "DEEPSEEK_BASE_URL=~A~%" final-url))
    (make-llm-config
     :provider :deepseek
     :api-key final-key
     :base-url final-url
     :model final-model)))

(defun current-date-string ()
  "返回 YYYY-MM-DD 格式的今日日期。"
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (declare (ignore sec min hour))
    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)))
