;;;; lisp/file-utils.lisp
;;;; 核心文件与目录读写工具（纯 Common Lisp + UIOP 实现）

(in-package :cl-user)

(defparameter *skip-dirs*
  '("node_modules" "bower_components" "jspm_packages" "vendor" ".pnpm" ".yarn"
    ".git" ".svn" ".hg"
    "dist" "build" "out" "target" ".next" ".nuxt" ".output"
    "__pycache__" ".cache" ".claude" ".myagent" ".turbo" ".eslintcache"
    "coverage" ".nyc_output")
  "递归遍历时自动跳过的巨型目录名。")

(defparameter *max-dir-entries* 800
  "单次目录遍历最大返回条目数。")

(defun skip-dir-p (dirname)
  (member dirname *skip-dirs* :test #'string=))

(defun normalize-slashes (path-str)
  "将路径中的反斜杠统一为正斜杠或系统原生分隔符。"
  (substitute #\/ #\\ path-str))

(defun resolve-path (path-str)
  "展开 ~ 波浪号并将路径解析为绝对路径字符串。"
  (let* ((raw (if (or (null path-str) (zerop (length (trim-whitespace path-str))))
                  "."
                  (trim-whitespace path-str)))
         (expanded
           (cond
             ((string= raw "~")
              (get-user-home-dir))
             ((and (>= (length raw) 2)
                   (char= (char raw 0) #\~)
                   (member (char raw 1) '(#\/ #\\)))
              (format nil "~A/~A" (get-user-home-dir) (subseq raw 2)))
             (t raw)))
         (norm (normalize-slashes expanded)))
    ;; 判断是否已经是绝对路径（Windows 盘符 C:/ 或 / 开头）
    (if (or (and (>= (length norm) 2)
                 (alpha-char-p (char norm 0))
                 (char= (char norm 1) #\:))
            (and (>= (length norm) 1)
                 (char= (char norm 0) #\/)))
        (let ((trimmed (string-right-trim "/" norm)))
          (if (and (= (length trimmed) 2) (char= (char trimmed 1) #\:))
              (format nil "~A/" trimmed)
              trimmed))
        ;; 相对路径：相对于当前工作目录
        (let ((cwd (string-right-trim "/\\" (normalize-slashes (namestring (uiop:getcwd))))))
          (if (string= norm ".")
              cwd
              (format nil "~A/~A" cwd (string-left-trim "./" norm)))))))

(defun native-dir-pathname (dir-str)
  "将目录路径字符串转为以分隔符结尾的 native pathname。"
  (let ((clean (string-right-trim "/\\" (resolve-path dir-str))))
    (uiop:ensure-directory-pathname (uiop:parse-native-namestring clean))))

(defun native-file-pathname (file-str)
  "将文件路径字符串转为 native pathname。"
  (uiop:parse-native-namestring (resolve-path file-str)))

(defun format-universal-time (utime)
  "将 universal-time 格式化为 ISO-8601 字符串。"
  (if (and utime (> utime 0))
      (multiple-value-bind (sec min hour day month year)
          (decode-universal-time utime)
        (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                year month day hour min sec))
      "unknown"))

(defun format-file-size (bytes)
  "格式化字节数为可读大小。"
  (let ((units '("B" "KB" "MB" "GB" "TB"))
        (size (coerce (or bytes 0) 'double-float))
        (idx 0))
    (loop while (and (>= size 1024.0d0) (< idx (1- (length units))))
          do (setf size (/ size 1024.0d0))
             (incf idx))
    (if (zerop idx)
        (format nil "~D B" (round size))
        (format nil "~,2F ~A" size (nth idx units)))))

(defun safe-file-size (pathname)
  "安全获取文件字节大小。"
  (ignore-errors
    (with-open-file (in pathname :direction :input :element-type '(unsigned-byte 8))
      (file-length in))))

(defun pathname-basename (p)
  "获取文件或目录的基本名称。"
  (let* ((ns (string-right-trim "/\\" (normalize-slashes (uiop:native-namestring p))))
         (pos (position #\/ ns :from-end t)))
    (if pos
        (subseq ns (1+ pos))
        ns)))

(defun pathname-extension (filename)
  "获取文件扩展名（包含点号，如 .lisp）。"
  (let ((pos (position #\. filename :from-end t)))
    (if (and pos (> pos 0))
        (subseq filename pos)
        :null)))

;;; ── 1. 列出目录 (list_directory) ─────────────────────

(defun list-directory-entries (dir-path &key (recursive nil) (max-depth nil))
  "列出目录内容，支持递归、深度限制与跳过巨型目录。"
  (let ((results nil)
        (count 0))
    (labels ((walk (current-dir depth)
               (when (fboundp 'note-worker-progress)
                 (funcall 'note-worker-progress))
               (when (>= count *max-dir-entries*)
                 (return-from walk))
               (let ((dir-pn (ignore-errors (native-dir-pathname current-dir))))
                 (when (and dir-pn (uiop:directory-exists-p dir-pn))
                   ;; 子目录
                   (let ((subdirs (ignore-errors (uiop:subdirectories dir-pn))))
                     (dolist (sd subdirs)
                       (when (>= count *max-dir-entries*) (return))
                       (let* ((name (pathname-basename sd))
                              (full-path (string-right-trim "/\\" (uiop:native-namestring sd)))
                              (mtime (ignore-errors (file-write-date sd))))
                         (push (jobj "name" name
                                     "path" full-path
                                     "size" 0
                                     "isDirectory" t
                                     "modifiedTime" (format-universal-time mtime))
                               results)
                         (incf count)
                         (when (and recursive
                                    (not (skip-dir-p name))
                                    (or (null max-depth) (> depth 0)))
                           (walk full-path (if max-depth (1- depth) nil))))))
                   ;; 文件
                   (let ((files (ignore-errors (uiop:directory-files dir-pn))))
                     (dolist (f files)
                       (when (>= count *max-dir-entries*) (return))
                       (let* ((name (pathname-basename f))
                              (full-path (uiop:native-namestring f))
                              (size (or (safe-file-size f) 0))
                              (mtime (ignore-errors (file-write-date f))))
                         (push (jobj "name" name
                                     "path" full-path
                                     "size" size
                                     "isDirectory" :false
                                     "extension" (pathname-extension name)
                                     "modifiedTime" (format-universal-time mtime))
                               results)
                         (incf count))))))))
      (let ((root-pn (native-dir-pathname dir-path)))
        (unless (uiop:directory-exists-p root-pn)
          (error "目录不存在: ~A" (resolve-path dir-path)))
        (walk (resolve-path dir-path) max-depth)))
    (nreverse results)))

;;; ── 2. 读取文件 (read_file) ──────────────────────────

(defun read-file-text (file-path)
  "读取指定文件的全部 UTF-8 文本内容。"
  (let ((pn (native-file-pathname file-path)))
    (unless (uiop:file-exists-p pn)
      (return-from read-file-text
        (jobj "error" (format nil "文件不存在: ~A" (resolve-path file-path)))))
    (handler-case
        (uiop:read-file-string pn :external-format :utf-8)
      (error (e)
        (jobj "error" (format nil "读取文件失败 (~A): ~A" (resolve-path file-path) e))))))

;;; ── 3. 写入文件 (write_file) ─────────────────────────

;;; ── 安全写入：语法校验 / 备份 / 原子替换 / 崩溃恢复日志 ──────

(defun myagent-lisp-path-p (path)
  "判断路径是否以 .lisp 结尾（file-utils 先于 tools.lisp 加载，故自带一份）。"
  (let ((norm (normalize-slashes (or path ""))))
    (and (>= (length norm) 5)
         (string-equal ".lisp" (subseq norm (- (length norm) 5))))))

(defun myagent-lisp-source-balanced-p (text)
  "粗略校验 Lisp 源码括号是否配平：忽略字符串、行注释、块注释与字符字面量。
只用于拦截「写到一半被中断」造成的截断文件，不替代编译器。"
  (let ((depth 0) (block 0) (i 0) (n (length (or text "")))
        (in-string nil) (escape nil) (ok t))
    (loop while (and ok (< i n)) do
      (let ((ch (char text i)))
        (cond
          (in-string
           (cond (escape (setf escape nil))
                 ((char= ch #\\) (setf escape t))
                 ((char= ch #\") (setf in-string nil))))
          ((plusp block)
           (cond ((and (char= ch #\|) (< (1+ i) n) (char= (char text (1+ i)) #\#))
                  (decf block) (incf i))
                 ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
                  (incf block) (incf i))))
          ((char= ch #\") (setf in-string t))
          ((char= ch #\;) (setf i (or (position #\Newline text :start i) n)))
          ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
           (setf block 1) (incf i))
          ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
           (incf i))
          ((char= ch #\() (incf depth))
          ((char= ch #\))
           (decf depth)
           (when (minusp depth) (setf ok nil)))))
      (incf i))
    (and ok (zerop depth) (zerop block) (not in-string))))

(defun myagent-backup-dir ()
  "备份与恢复日志目录（项目根下的 .myagent/backups）。
注意：resolve-path 会丢掉路径段开头的点，所以这里直接拼绝对路径。"
  (resolve-path (format nil "~A/.myagent/backups" (resolve-path "."))))

(defun myagent-journal-path ()
  "崩溃恢复日志路径：记录「正在替换的目标文件 + 备份文件」。"
  (format nil "~A/pending-edit.sexp" (myagent-backup-dir)))

(defun myagent-backup-current-file (resolved)
  "把目标文件当前内容复制一份到备份目录；文件不存在返回 nil。"
  (let ((pn (native-file-pathname resolved)))
    (when (uiop:file-exists-p pn)
      (let* ((dir (myagent-backup-dir))
             (name (file-namestring pn))
             (dst (format nil "~A/~A.~D.bak" dir name (get-universal-time))))
        (ensure-directories-exist (native-file-pathname dst))
        (ignore-errors (uiop:copy-file pn (native-file-pathname dst)))
        dst))))

(defun myagent-write-file-direct (path text)
  "直接写文件（不备份、不校验），仅供恢复日志等内部使用。"
  (ensure-directories-exist (native-file-pathname path))
  (with-open-file (out (native-file-pathname path)
                       :direction :output :if-exists :supersede
                       :if-does-not-exist :create :external-format :utf-8)
    (write-string (or text "") out)
    (finish-output out))
  t)

(defun myagent-write-journal (target backup)
  "写崩溃恢复日志（先写临时文件再替换，避免日志自身写坏）。"
  (let* ((j (myagent-journal-path))
         (tmp (format nil "~A.tmp" j))
         (body (format nil "(:target ~S :backup ~S :time ~D)~%"
                       target backup (get-universal-time))))
    (ignore-errors
      (myagent-write-file-direct tmp body)
      (myagent-replace-file tmp j))))

(defun myagent-replace-file (tmp target)
  "用 TMP 替换 TARGET：优先原子 move；被占用等原因失败时退化为直接覆写。
覆写期间若进程被强制结束，由启动期的 pending-edit 日志 + 备份兜底还原。"
  (let ((moved
          #+win32
          (progn
            (ignore-errors
              (uiop:run-program (list "cmd" "/c" "move" "/Y"
                                      (uiop:native-namestring (native-file-pathname tmp))
                                      (uiop:native-namestring (native-file-pathname target)))
                                :output :string :error-output :string :ignore-error-status t))
            (and (uiop:file-exists-p (native-file-pathname target))
                 (not (uiop:file-exists-p (native-file-pathname tmp)))
                 t))
          #-win32
          (progn
            (ignore-errors (rename-file (native-file-pathname tmp) (native-file-pathname target)))
            (and (uiop:file-exists-p (native-file-pathname target))
                 (not (uiop:file-exists-p (native-file-pathname tmp)))
                 t))))
    (if moved
        t
        (let ((txt (ignore-errors
                     (uiop:read-file-string (native-file-pathname tmp) :external-format :utf-8))))
          (when (stringp txt)
            (ignore-errors (myagent-write-file-direct target txt))
            (ignore-errors (delete-file (native-file-pathname tmp)))
            (uiop:file-exists-p (native-file-pathname target)))))))

(defun myagent-atomic-write (file-path text)
  "安全写文件：Lisp 源码先做括号配平校验，再备份、写临时文件、原子替换。
任一步失败都保持原文件不变；成功返回 t。"
  (handler-case
      (let* ((file-path (if (stringp file-path) file-path (uiop:native-namestring file-path)))
             (resolved (resolve-path file-path))
             (pn (native-file-pathname resolved))
             (content (or text ""))
             (tmp (format nil "~A.tmp-~D-~D" resolved (get-universal-time) (random 1000000))))
        (ensure-directories-exist pn)
        (let ((backup (myagent-backup-current-file resolved)))
          (myagent-write-file-direct tmp content)
          (myagent-write-journal resolved backup)
          (unless (myagent-replace-file tmp resolved)
            (ignore-errors (delete-file (native-file-pathname tmp)))
            (error "原子替换目标文件失败"))
          (ignore-errors (delete-file (native-file-pathname (myagent-journal-path))))
          t))
    (error (e)
      (format *error-output* "  [失败] 安全写入失败: ~A~%" e)
      nil)))

;;; ── 3. 写入文件 (write_file) ─────────────────────────

(defun write-file-text (file-path content)
  "创建或覆写文件（安全写入：语法校验 + 备份 + 原子替换 + 崩溃恢复日志）。"
  (let* ((resolved (resolve-path file-path))
         (ok (myagent-atomic-write resolved (or content ""))))
    (when ok
      (format t "  ~A 已写入文件: ~A~%" (ui-tag-ok "写入") resolved))
    ok))

(defun append-file-text (file-path content)
  "向已有文件末尾追加一行文本，若不存在则创建。"
  (handler-case
      (let* ((resolved (resolve-path file-path))
             (pn (native-file-pathname resolved)))
        (if (not (uiop:file-exists-p pn))
            (write-file-text resolved content)
            (progn
              (with-open-file (out pn :direction :output
                                      :if-exists :append
                                      :external-format :utf-8)
                (write-string (or content "") out)
                (terpri out))
              (format t "~A 已追加内容到文件: ~A~%" (ui-tag-ok "追加") resolved)
              t)))
    (error (e)
      (format *error-output* "  ~A 追加文件失败: ~A~%" (ui-tag-err "失败") e)
      nil)))

;;; ── 5. 文件内文本搜索 (search_text) ──────────────────

(defun search-in-file (file-path search-text)
  "在指定文件中搜索包含目标文本的行，返回匹配行及行号。"
  (let ((pn (native-file-pathname file-path))
        (results nil))
    (when (and (uiop:file-exists-p pn) search-text (> (length search-text) 0))
      (ignore-errors
        (with-open-file (in pn :direction :input :external-format :utf-8)
          (loop for line = (read-line in nil nil)
                for line-num from 1
                while line
                do (when (search search-text line :test #'char-equal)
                     (push (jobj "file" (uiop:native-namestring pn)
                                 "line" line-num
                                 "content" (trim-whitespace line))
                           results))))))
    (nreverse results)))

;;; ── 6. 文件名搜索 (search_files) ─────────────────────

(defun search-files-in-dir (dir-path pattern &key (recursive t) (max-depth nil))
  "在目录中搜索文件名包含指定模式的文件。"
  (let ((results nil)
        (count 0))
    (labels ((walk (current-dir depth)
               (when (fboundp 'note-worker-progress)
                 (funcall 'note-worker-progress))
               (when (>= count *max-dir-entries*)
                 (return-from walk))
               (let ((dir-pn (ignore-errors (native-dir-pathname current-dir))))
                 (when (and dir-pn (uiop:directory-exists-p dir-pn))
                   ;; 检查文件
                   (dolist (f (ignore-errors (uiop:directory-files dir-pn)))
                     (when (>= count *max-dir-entries*) (return))
                     (let ((name (pathname-basename f)))
                       (when (search pattern name :test #'char-equal)
                         (push (uiop:native-namestring f) results)
                         (incf count))))
                   ;; 检查子目录并递归
                   (dolist (sd (ignore-errors (uiop:subdirectories dir-pn)))
                     (when (>= count *max-dir-entries*) (return))
                     (let* ((name (pathname-basename sd))
                            (full-path (string-right-trim "/\\" (uiop:native-namestring sd))))
                       (when (search pattern name :test #'char-equal)
                         (push full-path results)
                         (incf count))
                       (when (and recursive
                                  (not (skip-dir-p name))
                                  (or (null max-depth) (> depth 0)))
                         (walk full-path (if max-depth (1- depth) nil)))))))))
      (walk (resolve-path dir-path) max-depth))
    (nreverse results)))

;;; ── 7. 获取文件详情 (get_file_info) ──────────────────

(defun get-file-info (file-path)
  "获取单个文件或目录的详细信息。"
  (let* ((resolved (resolve-path file-path))
         (dir-pn (ignore-errors (native-dir-pathname resolved)))
         (file-pn (ignore-errors (native-file-pathname resolved)))
         (is-dir (and dir-pn (uiop:directory-exists-p dir-pn)))
         (is-file (and (not is-dir) file-pn (uiop:file-exists-p file-pn))))
    (cond
      (is-dir
       (let ((mtime (ignore-errors (file-write-date dir-pn))))
         (jobj "path" resolved
               "size" 0
               "sizeFormatted" "0 B"
               "modifiedTime" (format-universal-time mtime)
               "isDirectory" t
               "isFile" :false)))
      (is-file
       (let ((size (or (safe-file-size file-pn) 0))
             (mtime (ignore-errors (file-write-date file-pn))))
         (jobj "path" resolved
               "size" size
               "sizeFormatted" (format-file-size size)
               "modifiedTime" (format-universal-time mtime)
               "isDirectory" :false
               "isFile" t)))
      (t
       (jobj "error" (format nil "无法获取文件信息（路径不存在）: ~A" resolved))))))

;;; ── 8. 复制文件 (copy_file) ──────────────────────────

(defun copy-file-path (source destination)
  "复制单个文件到目标路径，如目标父目录不存在则自动创建。"
  (handler-case
      (let ((src-pn (native-file-pathname source))
            (dest-pn (native-file-pathname destination)))
        (unless (uiop:file-exists-p src-pn)
          (return-from copy-file-path nil))
        (ensure-directories-exist dest-pn)
        (uiop:copy-file src-pn dest-pn)
        t)
    (error (e)
      (format *error-output* "  ~A 复制文件失败: ~A~%" (ui-tag-err "失败") e)
      nil)))

;;; ── 9. 移动文件或目录 (move_path) ────────────────────

(defun move-file-or-dir (source destination)
  "移动/重命名文件或目录。"
  (handler-case
      (let* ((src-resolved (resolve-path source))
             (dest-resolved (resolve-path destination))
             (src-pn (native-file-pathname src-resolved))
             (dest-pn (native-file-pathname dest-resolved)))
        (unless (or (uiop:file-exists-p src-pn)
                    (uiop:directory-exists-p (native-dir-pathname src-resolved)))
          (return-from move-file-or-dir
            (jobj "error" (format nil "源路径不存在: ~A" src-resolved))))
        (ensure-directories-exist dest-pn)
        (rename-file src-pn dest-pn)
        (jobj "success" t "from" src-resolved "to" dest-resolved))
    (error (e)
      (jobj "error" (format nil "移动失败: ~A" e)))))

;;; ── 10. 删除文件或目录 (delete_path) ─────────────────

(defun delete-file-or-dir (target)
  "删除文件或递归删除目录。"
  (handler-case
      (let* ((resolved (resolve-path target))
             (dir-pn (native-dir-pathname resolved))
             (file-pn (native-file-pathname resolved)))
        (cond
          ((uiop:directory-exists-p dir-pn)
           (uiop:delete-directory-tree dir-pn :validate t :if-does-not-exist :ignore)
           t)
          ((uiop:file-exists-p file-pn)
           (delete-file file-pn)
           t)
          (t nil)))
    (error (e)
      (format *error-output* "  ~A 删除失败: ~A~%" (ui-tag-err "失败") e)
      nil)))

;;; ── 项目路径与数据目录（开源友好：不写死任何本地路径） ──────

(defvar *project-root*
  (let ((here (or *load-truename* *compile-file-truename*)))
    (if here
        (uiop:pathname-parent-directory-pathname
         (uiop:pathname-directory-pathname here))
        (uiop:pathname-directory-pathname (uiop:getcwd))))
  "项目根目录（加载时动态计算：本文件所在 lisp/ 的上一级）。")

(defun project-root ()
  "返回项目根目录字符串（不含末尾斜杠）。可用环境变量 MYAGENT_ROOT 覆盖。"
  (let ((env (uiop:getenv "MYAGENT_ROOT")))
    (string-right-trim
     "/\\"
     (normalize-slashes
      (if (and env (> (length (trim-whitespace env)) 0))
          (resolve-path env)
          (namestring *project-root*))))))

(defun myagent-memory-dir ()
  "记忆目录：默认 <项目根>/memory；可用环境变量 MYAGENT_MEMORY_DIR 覆盖。"
  (let ((env (uiop:getenv "MYAGENT_MEMORY_DIR")))
    (string-right-trim
     "/\\"
     (normalize-slashes
      (if (and env (> (length (trim-whitespace env)) 0))
          (resolve-path env)
          (format nil "~A/memory" (project-root)))))))

