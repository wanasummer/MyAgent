;;;; lisp/tools.lisp
;;;; 动态工具注册表、工具执行器与工具注册
;;;; 注意：热重载 / 自动回滚引擎已拆分到 lisp/reload-engine.lisp，
;;;;      这样即使本文件被改坏，回滚引擎依然可用。

(in-package :cl-user)

(defun lisp-file-p (filepath)
  "判断路径是否为 .lisp 文件。"
  (let ((norm (normalize-slashes filepath)))
    (and (>= (length norm) 5)
         (string-equal ".lisp" (subseq norm (- (length norm) 5))))))

;;; ── 动态工具注册表 ───────────────────────────────────

(defstruct registered-tool
  name
  description
  input-schema
  handler)

(defvar *tool-registry* (make-hash-table :test 'equal)
  "全局动态工具表：name -> registered-tool。支持运行时动态新增或重定义工具。")

(defvar *tool-names-order* nil
  "保持工具定义的注册顺序。")

(defun register-tool (name description properties required handler)
  "注册或热更新一个工具。在运行时调用即可立即对下一轮 LLM 推理生效。"
  (let* ((schema (jobj "type" "object"
                       "properties" properties
                       "required" (or required nil)))
         (tool (make-registered-tool
                :name name
                :description description
                :input-schema schema
                :handler handler)))
    (setf (gethash name *tool-registry*) tool)
    (unless (member name *tool-names-order* :test #'string=)
      (setf *tool-names-order* (append *tool-names-order* (list name))))
    name))

(defun get-all-tool-definitions ()
  "获取当前已注册的所有工具定义列表（Anthropic input_schema 格式）。"
  (let ((defs nil))
    (dolist (name *tool-names-order*)
      (let ((t-entry (gethash name *tool-registry*)))
        (when t-entry
          (push (jobj "name" (registered-tool-name t-entry)
                      "description" (registered-tool-description t-entry)
                      "input_schema" (registered-tool-input-schema t-entry))
                defs))))
    (nreverse defs)))

(defun execute-tool (name args)
  "根据工具名称分派执行，返回字符串或可 JSON 序列化的结构。"
  (let ((t-entry (gethash name *tool-registry*)))
    (if t-entry
        (funcall (registered-tool-handler t-entry) (or args (jobj)))
        (jobj "error" (format nil "未知工具: ~A" name)))))

(defun prop-spec (type description &key enum)
  "辅助构造 JSON Schema 属性定义。"
  (let ((ht (jobj "type" type "description" description)))
    (when enum
      (setf (jget ht "enum") enum))
    ht))

;;; ── 注册核心文件读写工具 ─────────────────────────────

(register-tool
 "list_directory"
 "列出指定目录下的所有文件和子目录。返回文件名、路径、大小、类型等信息。在操作任何文件之前，先用此工具了解目录结构。"
 (jobj "dirPath" (prop-spec "string" "要列出的目录路径（绝对路径或相对路径），默认为当前工作目录 '.'")
       "recursive" (prop-spec "boolean" "是否递归列出子目录的内容，默认为 false")
       "maxDepth" (prop-spec "number" "最大递归深度，可选。推荐：查看项目结构时用 2~3。"))
 '("dirPath")
 (lambda (args)
   (list-directory-entries
    (or (jget args "dirPath") ".")
    :recursive (jtrue-p (jget args "recursive"))
    :max-depth (let ((md (jget args "maxDepth")))
                 (if (integerp md) md nil)))))

(register-tool
 "read_file"
 "读取指定文件的全部内容，以 UTF-8 文本返回。"
 (jobj "filePath" (prop-spec "string" "要读取的文件路径"))
 '("filePath")
 (lambda (args)
   (read-file-text (jget args "filePath"))))

(register-tool
 "write_file"
 "创建新文件或覆写已有文件，写入指定的文本内容。如果父目录不存在会自动创建。若修改的是 .lisp 文件，系统会自动热重载；若重载失败会自动回滚到上一个可用版本并把编译错误返回给你（任务不会中断），此时你必须修复代码后重新写入。"
 (jobj "filePath" (prop-spec "string" "要创建/覆写的文件路径")
       "content" (prop-spec "string" "要写入文件的内容"))
 '("filePath" "content")
 (lambda (args)
   (let* ((fp (jget args "filePath"))
          (content (or (jget args "content") ""))
          (ok (write-file-text fp content)))
     (if (and ok (lisp-file-p fp))
         (multiple-value-bind (reload-ok reload-msg rolled-back)
             (hot-reload-lisp-file fp)
           (if reload-ok
               (jobj "success" t
                     "written" t
                     "hotReloaded" t
                     "reloadMessage" reload-msg)
               (jobj "success" :false
                     "written" t
                     "hotReloaded" :false
                     "rolledBack" (if rolled-back t :false)
                     "reloadMessage" reload-msg
                     "hint" (if rolled-back
                               "重载失败，磁盘文件与内存定义已自动回滚到上一个可用版本。请修复错误后重新写入。"
                               "重载失败且未能完全回滚，请立即修复该文件并重新写入。"))))
         (jobj "success" (if ok t :false))))))

(register-tool
 "append_file"
 "向已有文件末尾追加一行文本内容。如果文件不存在则创建。若修改的是 .lisp 文件，会自动触发热重载；重载失败会自动回滚到上一个可用版本并把错误返回给你（任务不会中断）。"
 (jobj "filePath" (prop-spec "string" "要追加内容的文件路径")
       "content" (prop-spec "string" "要追加的内容"))
 '("filePath" "content")
 (lambda (args)
   (let* ((fp (jget args "filePath"))
          (content (or (jget args "content") ""))
          (ok (append-file-text fp content)))
     (if (and ok (lisp-file-p fp))
         (multiple-value-bind (reload-ok reload-msg rolled-back)
             (hot-reload-lisp-file fp)
           (if reload-ok
               (jobj "success" t
                     "written" t
                     "hotReloaded" t
                     "reloadMessage" reload-msg)
               (jobj "success" :false
                     "written" t
                     "hotReloaded" :false
                     "rolledBack" (if rolled-back t :false)
                     "reloadMessage" reload-msg
                     "hint" (if rolled-back
                               "重载失败，磁盘文件与内存定义已自动回滚到上一个可用版本。请修复错误后重新写入。"
                               "重载失败且未能完全回滚，请立即修复该文件并重新写入。"))))
         (jobj "success" (if ok t :false))))))

(register-tool
 "search_text"
 "在指定文件中搜索包含目标文本的行，返回匹配行及其行号。"
 (jobj "filePath" (prop-spec "string" "要搜索的文件路径")
       "searchText" (prop-spec "string" "要搜索的关键词或文本"))
 '("filePath" "searchText")
 (lambda (args)
   (search-in-file (jget args "filePath") (jget args "searchText"))))

(register-tool
 "search_files"
 "在目录中搜索文件名匹配指定模式的文件。自动跳过 node_modules、.git、dist 等巨型目录。"
 (jobj "dirPath" (prop-spec "string" "要搜索的目录路径")
       "pattern" (prop-spec "string" "文件名包含的关键词或后缀，如 '.lisp' 或 'agent'")
       "recursive" (prop-spec "boolean" "是否递归搜索子目录，默认为 true")
       "maxDepth" (prop-spec "number" "最大递归深度，可选"))
 '("dirPath" "pattern")
 (lambda (args)
   (let ((rec (jget args "recursive" t)))
     (search-files-in-dir
      (or (jget args "dirPath") ".")
      (or (jget args "pattern") "")
      :recursive (not (eq rec :false))
      :max-depth (let ((md (jget args "maxDepth")))
                   (if (integerp md) md nil))))))

(register-tool
 "get_file_info"
 "获取单个文件或目录的详细信息，包括大小、最后修改时间、是否为目录等。"
 (jobj "filePath" (prop-spec "string" "要查询的文件路径"))
 '("filePath")
 (lambda (args)
   (get-file-info (jget args "filePath"))))

(register-tool
 "copy_file"
 "将单个文件从源路径复制到目标路径。如目标目录不存在会自动创建。"
 (jobj "source" (prop-spec "string" "源文件路径")
       "destination" (prop-spec "string" "目标文件路径"))
 '("source" "destination")
 (lambda (args)
   (jobj "success" (if (copy-file-path (jget args "source") (jget args "destination"))
                       t :false))))

(register-tool
 "move_path"
 "移动文件或整个目录到新位置。"
 (jobj "source" (prop-spec "string" "源文件或目录路径")
       "destination" (prop-spec "string" "目标路径"))
 '("source" "destination")
 (lambda (args)
   (move-file-or-dir (jget args "source") (jget args "destination"))))

(register-tool
 "delete_path"
 "删除文件或目录。如果是目录则递归删除其下所有内容。请谨慎使用！删除前必须确认用户意图。"
 (jobj "target" (prop-spec "string" "要删除的文件或目录路径"))
 '("target")
 (lambda (args)
   (jobj "success" (if (delete-file-or-dir (jget args "target"))
                       t :false))))

;;; ── 持久化记忆管理 (~/.myagent/memory/*.md) ──────────

(defun get-memory-dir ()
  "记忆目录：默认 <项目根>/memory；可用环境变量 MYAGENT_MEMORY_DIR 覆盖。"
  (myagent-memory-dir))

(defun parse-memory-file (filepath)
  "解析单个记忆 Markdown 文件的 frontmatter 与正文。"
  (let ((raw (read-file-text filepath)))
    (when (stringp raw)
      (let* ((trimmed (trim-whitespace raw)))
        (when (and (>= (length trimmed) 3)
                   (string= "---" (subseq trimmed 0 3)))
          (let ((end-pos (search (format nil "~%---") trimmed :start2 3)))
            (when end-pos
              (let* ((yaml-part (subseq trimmed 3 end-pos))
                     (body-start (position #\Newline trimmed :start (+ end-pos 4)))
                     (body (if body-start (trim-whitespace (subseq trimmed (1+ body-start))) ""))
                     (name nil)
                     (desc "")
                     (mtype "reference"))
                (with-input-from-string (s yaml-part)
                  (loop for line = (read-line s nil nil)
                        while line
                        for tl = (trim-whitespace line)
                        do (cond
                             ((and (>= (length tl) 5) (string= "name:" (subseq tl 0 5)))
                              (setf name (trim-whitespace (subseq tl 5))))
                             ((and (>= (length tl) 12) (string= "description:" (subseq tl 0 12)))
                              (setf desc (trim-whitespace (subseq tl 12))))
                             ((and (>= (length tl) 5) (string= "type:" (subseq tl 0 5)))
                              (setf mtype (trim-whitespace (subseq tl 5)))))))
                (when name
                  (jobj "name" name
                        "description" desc
                        "type" mtype
                        "content" body
                        "filePath" filepath))))))))))

(defun load-all-memories ()
  "读取 ~/.myagent/memory/ 下的所有记忆。"
  (let* ((mdir (get-memory-dir))
         (dir-pn (ignore-errors (native-dir-pathname mdir)))
         (memories nil))
    (when (and dir-pn (uiop:directory-exists-p dir-pn))
      (dolist (f (ignore-errors (uiop:directory-files dir-pn)))
        (let ((bname (pathname-basename f)))
          (when (and (not (string-equal bname "MEMORY.md"))
                     (> (length bname) 3)
                     (string-equal ".md" (subseq bname (- (length bname) 3))))
            (let ((parsed (parse-memory-file (uiop:native-namestring f))))
              (when parsed
                (push parsed memories)))))))
    (nreverse memories)))

(register-tool
 "list_memories"
 "列出所有已保存的持久化记忆摘要。"
 (jobj)
 nil
 (lambda (args)
   (declare (ignore args))
   (let ((mems (load-all-memories)))
     (jobj "count" (length mems)
           "memories" (mapcar (lambda (m)
                                (jobj "name" (jget m "name")
                                      "description" (jget m "description")
                                      "type" (jget m "type")))
                              mems)))))

(register-tool
 "recall_memory"
 "读取某条记忆的完整内容。"
 (jobj "name" (prop-spec "string" "要读取的记忆名称"))
 '("name")
 (lambda (args)
   (let* ((target-name (jget args "name"))
          (mems (load-all-memories))
          (found (find-if (lambda (m) (string= (jget m "name") target-name)) mems)))
     (if found
         found
         (jobj "error" (format nil "未找到记忆: ~A" target-name))))))

(register-tool
 "save_memory"
 "保存一条持久化记忆到 ~/.myagent/memory/ 目录中，跨会话保留。"
 (jobj "name" (prop-spec "string" "记忆名称（kebab-case 格式）")
       "description" (prop-spec "string" "一行概要描述")
       "type" (prop-spec "string" "记忆类型：user | feedback | project | reference")
       "content" (prop-spec "string" "记忆的完整 Markdown 内容"))
 '("name" "description" "type" "content")
 (lambda (args)
   (let* ((name (jget args "name"))
          (desc (or (jget args "description") ""))
          (mtype (or (jget args "type") "reference"))
          (content (or (jget args "content") ""))
          (fp (format nil "~A/~A.md" (get-memory-dir) name))
          (md (format nil "---~%name: ~A~%description: ~A~%metadata:~%  type: ~A~%---~%~%~A~%"
                      name desc mtype content)))
     (jobj "success" (if (write-file-text fp md) t :false)))))

(register-tool
 "delete_memory"
 "删除一条持久化记忆。"
 (jobj "name" (prop-spec "string" "要删除的记忆名称"))
 '("name")
 (lambda (args)
   (let ((fp (format nil "~A/~A.md" (get-memory-dir) (jget args "name"))))
     (jobj "success" (if (delete-file-or-dir fp) t :false)))))

(register-tool
 "search_memories"
 "搜索持久化记忆。根据查询词匹配最相关的记忆内容。"
 (jobj "query" (prop-spec "string" "要搜索的查询文本"))
 '("query")
 (lambda (args)
   (let* ((q (or (jget args "query") ""))
          (mems (load-all-memories))
          (matched (remove-if-not
                    (lambda (m)
                      (or (search q (jget m "name") :test #'char-equal)
                          (search q (jget m "description") :test #'char-equal)
                          (search q (jget m "content") :test #'char-equal)))
                    mems)))
     (jobj "count" (length matched)
           "results" (or matched mems)))))

;;; ── 注册 Lisp 原生热迭代工具 (Self-Iteration) ───────

(defvar *in-eval-lisp* nil
  "当前是否处于 eval_lisp 工具求值上下文中（用于防止控制台读取函数在自测时无限阻塞）。")

(defparameter *protected-console-fns*
  '(%console-fetch-records %console-peek-records %console-input-handle
    %console-wait-input console-pending-char-p)
  "eval_lisp 异常中断或超时时必须自动恢复的底层控制台 I/O 函数，防止临时 mock 忘还原导致终端彻底失灵。")

(defun snapshot-protected-fns ()
  (let ((saved nil))
    (dolist (sym *protected-console-fns*)
      (when (fboundp sym)
        (push (cons sym (symbol-function sym)) saved)))
    saved))

(defun restore-protected-fns (saved)
  (dolist (pair saved)
    (ignore-errors (setf (symbol-function (car pair)) (cdr pair)))))

(defun eval-lisp-string (code-str)
  "在当前 SBCL 镜像中顺序读取并求值一段或多段 S-表达式，捕获标准输出与返回值。
内置防卡死护栏：
1) 将 *standard-input* 绑定为空字符串流，防止 (read) / (read-line) 阻塞等待键盘；
2) 绑定 *in-eval-lisp* = t，让 read-console-line 在 mock 队列耗尽后自动退出而非无限 sleep；
3) 若求值因异常/超时/ESC 中断退出，自动还原被临时替换的底层控制台函数。"
  (let ((stdout-buf (make-string-output-stream))
        (empty-stdin (make-string-input-stream ""))
        (saved-fns (snapshot-protected-fns))
        (completed-ok nil)
        (last-val nil))
    (unwind-protect
         (handler-case
             (let ((*in-eval-lisp* t)
                   (*active-eval-stdout-stream* stdout-buf)
                   (*standard-input* empty-stdin)
                   (*standard-output* stdout-buf)
                   (*package* (find-package :cl-user))
                   #+sbcl (sb-ext:*muffled-warnings* 'style-warning))
               (with-input-from-string (in code-str)
                 (loop for form = (read in nil :eof)
                       until (eq form :eof)
                       do (when (fboundp 'note-worker-progress)
                            (funcall 'note-worker-progress))
                          (setf last-val (eval form))))
               (setf completed-ok t)
               (let ((out-str (get-output-stream-string stdout-buf)))
                 (jobj "success" t
                       "result" (prin1-to-string last-val)
                       "stdout" out-str)))
           (serious-condition (e)
             (let ((out-str (get-output-stream-string stdout-buf)))
               (jobj "success" :false
                     "error" (format nil "~A" e)
                     "stdout" out-str))))
      (unless completed-ok
        (restore-protected-fns saved-fns)))))

(register-tool
 "eval_lisp"
 "在当前正在运行的 Common Lisp (SBCL) 进程镜像中直接求值任意 S-表达式！可用于：(1) 动态定义或修改函数 (defun ...)；(2) 动态注册新工具 (register-tool ...)；(3) 读写/检查内存状态与全局变量；(4) 无需重启即可实时演进 Agent 的核心能力。"
 (jobj "code" (prop-spec "string" "要执行的 Common Lisp 代码（支持一个或多个顶层 S-表达式）"))
 '("code")
 (lambda (args)
   (eval-lisp-string (or (jget args "code") "nil"))))

(register-tool
 "reload_lisp"
 "热重载指定的 .lisp 源文件，或者不传 filePath 以重新加载全部核心模块 (lisp/*.lisp)。重载后所有函数与工具定义立即在当前会话生效，无需重启 CLI。若某个文件重载失败，会自动回滚到上一个可用版本并把错误返回给你，任务不会中断。"
 (jobj "filePath" (prop-spec "string" "可选，要热重载的 .lisp 文件路径。若为空则重载全部核心模块。"))
 nil
 (lambda (args)
   (let ((fp (jget args "filePath")))
     (if (and (stringp fp) (> (length (trim-whitespace fp)) 0) (not (eq fp :null)))
         (multiple-value-bind (ok msg rolled-back)
             (hot-reload-lisp-file fp)
           (jobj "success" (if ok t :false)
                 "rolledBack" (if rolled-back t :false)
                 "message" msg))
         (let ((messages nil)
               (all-ok t)
               (any-rollback nil))
           (dolist (f *core-lisp-files*)
             (multiple-value-bind (ok msg rolled-back)
                 (hot-reload-lisp-file f)
               (unless ok (setf all-ok nil))
               (when rolled-back (setf any-rollback t))
               (push (jobj "file" (resolve-path f)
                           "success" (if ok t :false)
                           "rolledBack" (if rolled-back t :false)
                           "message" msg)
                     messages)))
           (jobj "success" (if all-ok t :false)
                 "anyRolledBack" (if any-rollback t :false)
                 "reloaded" (nreverse messages)))))))
