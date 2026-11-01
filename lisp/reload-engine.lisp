;;;; lisp/reload-engine.lisp
;;;; 安全热重载引擎：失败自动回滚到「上一步」+ 错误回传给 Agent，任务不中断。
;;;;
;;;; 设计目标：
;;;;   1. 任何 .lisp 热重载失败都不会抛异常打断 Agent Loop；
;;;;   2. 失败时自动回滚「磁盘文件」与「内存定义」到上一个可用版本（上一步）；
;;;;   3. 失败信息通过工具返回值 / 待注入队列交还给 LLM，Agent 继续思考并修复。
;;;;
;;;; 本文件刻意与 tools.lisp 分离：即使 tools.lisp 自身被改坏，回滚引擎依然可用。

(in-package :cl-user)

;;; ── 全局状态（defvar 保证热重载时不丢失） ────────────

(defvar *loaded-file-mtimes* (make-hash-table :test 'equal)
  "已加载 .lisp 文件的最后修改时间 (universal-time)。")

(defvar *lisp-file-backups* (make-hash-table :test 'equal)
  "resolved path -> 上一次验证可用的源码文本，用于失败回滚（上一步快照）。")

(defvar *lisp-baseline-backups* (make-hash-table :test 'equal)
  "resolved path -> 进程启动时的初始黄金快照（永不覆盖，作为终极兜底）。")

(defvar *lisp-unverified-backups* (make-hash-table :test 'equal)
  "resolved path -> 本轮热重载前已验证通过的快照。
只有当下一轮 LLM 请求真正成功返回后，才调用 commit-verified-lisp-backups 确认；
若下一轮 LLM 请求在运行期直接崩溃（如 curl 参数错误），自动回滚此表中的所有文件。")

(defvar *pending-lisp-reload-errors* nil
  "待注入给 LLM 的热重载失败信息队列（外部修改触发的自动重载失败时写入）。")

(defparameter *max-pending-reload-errors* 10
  "待注入错误队列的最大长度。")

(defparameter *core-lisp-files*
  '("lisp/reload-engine.lisp"
    "lisp/json.lisp"
    "lisp/config.lisp"
    "lisp/ui.lisp"
    "lisp/file-utils.lisp"
    "lisp/markdown.lisp"
    "lisp/llm-client.lisp"
     "lisp/cancel.lisp"
    "lisp/supervisor.lisp"
    "lisp/tools.lisp"
    "lisp/self-iteration.lisp"
    "lisp/self-iteration-shadow.lisp"
    "lisp/agent-loop.lisp"
    "lisp/context-manager.lisp"
    "lisp/cli.lisp")
  "核心 Lisp 模块加载顺序（含安全重载引擎自身）。")

;;; ── 错误队列 ─────────────────────────────────────────

(defun record-lisp-reload-error (msg)
  "把一次热重载失败登记到待注入队列（只保留最近 N 条）。"
  (push msg *pending-lisp-reload-errors*)
  (when (> (length *pending-lisp-reload-errors*) *max-pending-reload-errors*)
    (setf *pending-lisp-reload-errors*
          (subseq *pending-lisp-reload-errors* 0 *max-pending-reload-errors*)))
  msg)

(defun drain-lisp-reload-errors ()
  "取出并清空待注入的热重载错误（按发生顺序返回列表）。"
  (prog1 (nreverse *pending-lisp-reload-errors*)
    (setf *pending-lisp-reload-errors* nil)))

;;; ── 基础读写与静默加载 ───────────────────────────────

(defun safe-read-file-content (pathname)
  "读取文件文本内容，失败返回 nil。"
  (ignore-errors (uiop:read-file-string pathname :external-format :utf-8)))

(defun safe-write-file-content (pathname content)
  "把字符串安全写入文件（自动创建父目录），成功返回 t。
若 file-utils 已加载，则走「校验 + 备份 + 原子替换 + 恢复日志」的安全路径。"
  (when (fboundp 'myagent-atomic-write)
    (return-from safe-write-file-content
      (funcall 'myagent-atomic-write pathname content)))
  (handler-case
      (progn
        (ensure-directories-exist pathname)
        (with-open-file (out pathname :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create
                                      :external-format :utf-8)
          (write-string (or content "") out))
        t)
    (serious-condition (e)
      (format *error-output* "  [失败] 写入失败 (~A): ~A~%"
              (ignore-errors (uiop:native-namestring pathname)) e)
      nil)))

(defun undefined-reference-problem-p (message)
  "若 MESSAGE 是「未定义函数 / 未定义变量」类编译期警告，且对应符号在加载完成后仍未定义，
返回问题描述字符串；否则返回 NIL。这类警告意味着代码运行到该分支时必然崩溃（典型例子：
flet 内互相调用，实际解析成了全局函数名）。"
  (let* ((fn-pos (search "undefined function:" message :test #'char-equal))
         (var-pos (search "undefined variable:" message :test #'char-equal))
         (pos (or fn-pos var-pos)))
    (when pos
      (let* ((is-fn (not (null fn-pos)))
             (prefix (if is-fn "undefined function:" "undefined variable:"))
             (raw (string-trim '(#\Space #\Tab #\Return)
                               (subseq message (+ pos (length prefix)))))
             (sym (ignore-errors (read-from-string raw))))
        (when (and sym (symbolp sym)
                   (if is-fn (not (fboundp sym)) (not (boundp sym))))
          (format nil "~A: ~A"
                  (if is-fn "未定义函数" "未定义变量")
                  raw))))))

(defun load-lisp-file-quietly (pathname)
  "静默加载一个 .lisp 文件；出错则抛出条件交由调用方处理。
加载完成后检查「未定义函数 / 未定义变量」告警：若加载结束后符号仍未定义，
说明运行期必崩（如 flet 内互相调用被解析成全局函数），直接抛错触发自动回滚。"
  (let ((*load-verbose* nil)
        (*load-print* nil)
        (suspects '())
        #+sbcl (sb-ext:*muffled-warnings* 'style-warning))
    (handler-bind
        ((warning (lambda (w)
                    (let ((s (princ-to-string w)))
                      (when (or (search "undefined function:" s :test #'char-equal)
                                (search "undefined variable:" s :test #'char-equal))
                        (push s suspects)))
                    (muffle-warning w))))
      (load pathname :external-format :utf-8))
    (let ((bad (remove-duplicates
                (remove nil (mapcar #'undefined-reference-problem-p suspects))
                :test #'equal)))
      (when bad
        (error "加载后发现未定义引用（运行到该分支必崩）: ~{~A~^；~}" bad))))
  t)

;;; ── 快照、失败转储与回滚 ─────────────────────────────

(defun snapshot-lisp-source! (resolved pathname)
  "把磁盘上的当前版本登记为「上一个可用版本」快照。"
  (let ((content (safe-read-file-content pathname)))
    (when (stringp content)
      (setf (gethash resolved *lisp-file-backups*) content)
      (unless (gethash resolved *lisp-baseline-backups*)
        (setf (gethash resolved *lisp-baseline-backups*) content))))
  t)

(defun seed-lisp-backups ()
  "为尚未建立快照的核心模块从磁盘补一份初始快照（只补空缺，不覆盖已有）。"
  (dolist (rel *core-lisp-files*)
    (ignore-errors
      (let* ((resolved (resolve-path rel))
             (pathname (native-file-pathname resolved)))
        (when (uiop:file-exists-p pathname)
          (when (null (gethash resolved *lisp-file-backups*))
            (snapshot-lisp-source! resolved pathname))
          (when (null (gethash resolved *lisp-baseline-backups*))
            (let ((c (safe-read-file-content pathname)))
              (when (stringp c)
                (setf (gethash resolved *lisp-baseline-backups*) c))))))))
  t)

;;; ── 核心模块冒烟自检（拦截 Load 成功但运行期必崩的修改） ──

(defvar *curl-compressed-support-cache* :unknown
  "缓存当前系统的 curl 是否支持 --compressed（编译了 libz/brotli/zstd）。")

(defun curl-supports-compressed-p ()
  "检测当前 curl 可执行文件是否支持 --compressed 参数。"
  (when (eq *curl-compressed-support-cache* :unknown)
    (setf *curl-compressed-support-cache*
          (handler-case
              (let ((exe (if (fboundp 'curl-executable)
                             (funcall 'curl-executable)
                             #+win32 "curl.exe" #-win32 "curl")))
                (multiple-value-bind (stdout stderr code)
                    (uiop:run-program (list exe "--version")
                                      :output :string
                                      :error-output :string
                                      :ignore-error-status t)
                  (declare (ignore stderr))
                  (and (eql code 0)
                       (stringp stdout)
                       (or (search "libz" stdout :test #'char-equal)
                           (search "brotli" stdout :test #'char-equal)
                           (search "zstd" stdout :test #'char-equal))
                       t)))
            (error () nil))))
  *curl-compressed-support-cache*)

(defun smoke-test-reloaded-file (resolved disk-content)
  "在 load 成功后对关键模块执行轻量级运行期冒烟自检。
若发现会引起大脑失联（LLM 无法通信 / JSON 损坏 / 主循环符号丢失）的缺陷，直接抛错触发自动回滚。"
  (let ((norm (if (fboundp 'normalize-slashes) (normalize-slashes resolved) resolved)))
    (cond
      ;; 1. LLM 客户端自检：符号完整性 + curl 参数兼容性
      ((search "llm-client.lisp" norm :test #'char-equal)
       (dolist (sym '(chat-with-tools http-post-json send-deepseek-request send-deepseek-request-stream))
         (unless (fboundp sym)
           (error "冒烟自检失败: llm-client.lisp 重载后缺失核心函数 ~A" sym)))
       (when (and (stringp disk-content)
                  (search "--compressed" disk-content :test #'char-equal)
                  (not (curl-supports-compressed-p)))
         (error "冒烟自检失败: 当前系统 curl (libcurl) 未编译 libz/brotli/zstd 特性，不支持 --compressed 参数（运行期会导致 curl exit 2 并使 Agent 失联）")))

      ;; 2. JSON 模块自检：编码与解码闭环
      ((search "json.lisp" norm :test #'char-equal)
       (dolist (sym '(jobj jget json-encode json-decode))
         (unless (fboundp sym)
           (error "冒烟自检失败: json.lisp 重载后缺失核心函数 ~A" sym)))
       (let* ((sample (funcall 'jobj "ok" t "num" 42 "txt" "test"))
              (enc (funcall 'json-encode sample))
              (dec (funcall 'json-decode enc)))
         (unless (and (hash-table-p dec)
                      (eql (funcall 'jget dec "num") 42)
                      (equal (funcall 'jget dec "txt") "test"))
           (error "冒烟自检失败: json-encode / json-decode 往返自检结果异常"))))

      ;; 3. Agent 主循环与工具表自检
      ((search "agent-loop.lisp" norm :test #'char-equal)
       (dolist (sym '(run-agent execute-tool-use-block))
         (unless (fboundp sym)
           (error "冒烟自检失败: agent-loop.lisp 重载后缺失核心函数 ~A" sym))))

      ((search "tools.lisp" norm :test #'char-equal)
       (dolist (sym '(execute-tool get-all-tool-definitions register-tool))
         (unless (fboundp sym)
           (error "冒烟自检失败: tools.lisp 重载后缺失核心函数 ~A" sym))))))
  t)

;;; ── 两阶段事务确认与运行期崩溃自动回滚 ───────────────

(defun unverified-lisp-backups-p ()
  "是否存在本轮热重载过、但尚未经过下一轮 LLM 通信验证的 .lisp 文件。"
  (and (hash-table-p *lisp-unverified-backups*)
       (plusp (hash-table-count *lisp-unverified-backups*))))

(defun commit-verified-lisp-backups ()
  "当 LLM 请求成功返回后调用：确认本轮热重载的所有代码均未破坏核心通信链路，清空待验证表。"
  (when (hash-table-p *lisp-unverified-backups*)
    (clrhash *lisp-unverified-backups*))
  t)

(defun rollback-unverified-lisp-files (&optional runtime-condition)
  "当 LLM 请求或主循环在运行期抛出异常时调用：
将所有尚未通过通信验证的 .lisp 文件自动回滚到改动前的可用版本，并把错误注入待通知队列。
返回 (values 已回滚文件列表 汇总消息)。"
  (let ((rolled nil)
        (details nil)
        (err-str (if runtime-condition (princ-to-string runtime-condition) "未知运行期错误")))
    (when (unverified-lisp-backups-p)
      (let ((entries nil))
        (maphash (lambda (k v) (push (cons k v) entries)) *lisp-unverified-backups*)
        (clrhash *lisp-unverified-backups*)
        (dolist (pair entries)
          (let* ((resolved (car pair))
                 (good-src (cdr pair))
                 (pathname (native-file-pathname resolved))
                 (bad-src (safe-read-file-content pathname)))
            (ignore-errors (save-failed-lisp-source resolved bad-src))
            (multiple-value-bind (disk-ok mem-ok notes)
                (rollback-lisp-file resolved pathname good-src)
              (declare (ignore notes))
              (when (and disk-ok mem-ok)
                (setf (gethash resolved *lisp-file-backups*) good-src)
                (setf (gethash resolved *loaded-file-mtimes*)
                      (or (ignore-errors (file-write-date pathname))
                          (get-universal-time)))
                (push resolved rolled)
                (push (format nil "- ~A（已回滚到改动前的可用快照，失败版本另存为 ~A.failed）"
                              resolved resolved)
                      details)))))))
    (let ((summary
            (format nil "[失败] 核心模块热重载后触发运行期异常（已自动回滚自愈，任务继续）~%运行期错误: ~A~%自动回滚的文件:~%~{~A~%~}-> 你刚才对上述 Lisp 核心文件的修改虽然通过了编译，但在下一轮运行期（如发起 HTTP 请求或主循环调用）时直接报错。系统已自动回滚到修改前的可用版本，请分析上述运行期错误原因后再重新修改。"
                    err-str (nreverse details))))
      (when rolled
        (record-lisp-reload-error summary)
        (format *error-output* "~%  ~A 检测到热重载后运行期崩溃: ~A~%      已自动回滚 ~D 个文件并恢复通信: ~{~A~^, ~}~%"
                (ui-tag-warn "自愈") err-str (length rolled) (nreverse (copy-list rolled))))
      (values (nreverse rolled) summary))))

(defun rollback-all-to-baseline ()
  "紧急兜底：将所有核心模块恢复到进程启动时的黄金快照（供 /rollback baseline 或严重故障使用）。"
  (let ((restored nil))
    (maphash (lambda (resolved baseline-src)
               (let ((pathname (native-file-pathname resolved)))
                 (multiple-value-bind (disk-ok mem-ok)
                     (rollback-lisp-file resolved pathname baseline-src)
                   (when (and disk-ok mem-ok)
                     (setf (gethash resolved *lisp-file-backups*) baseline-src)
                     (setf (gethash resolved *loaded-file-mtimes*)
                           (or (ignore-errors (file-write-date pathname))
                               (get-universal-time)))
                     (push resolved restored)))))
             *lisp-baseline-backups*)
    (clrhash *lisp-unverified-backups*)
    (nreverse restored)))

(defun save-failed-lisp-source (resolved content)
  "把加载失败的源码另存为 <文件>.failed，方便事后比对与修复。返回路径或 nil。"
  (if (not (stringp content))
      nil
      (let ((target (format nil "~A.failed" resolved)))
        (when (safe-write-file-content (native-file-pathname target) content)
          target))))

(defun rollback-lisp-file (resolved pathname previous-good)
  "把上一个可用版本回滚到磁盘并重新加载进内存。
返回 (values 磁盘已回滚-p 内存已回滚-p 备注列表)。"
  (if (not (stringp previous-good))
      (values nil nil (list "没有可用的回滚快照"))
      (let ((disk-ok nil)
            (mem-ok nil)
            (notes nil))
        (setf disk-ok (safe-write-file-content pathname previous-good))
        (unless disk-ok
          (push "磁盘文件回写失败" notes))
        (when disk-ok
          (setf mem-ok
                (handler-case (load-lisp-file-quietly pathname)
                  (serious-condition (e)
                    (push (format nil "内存回滚加载失败: ~A" e) notes)
                    nil))))
        (values disk-ok mem-ok (nreverse notes)))))

;;; ── 失败统一处理 ─────────────────────────────────────

(defun handle-reload-failure (resolved pathname condition failed-content previous-good
                                       rollback record quiet)
  "统一处理热重载失败：另存失败版本 → 回滚 → 组装错误信息 → 返回给调用方。
返回 (values nil 错误消息 已回滚-p)，绝不抛异常。"
  (let* ((error-text (princ-to-string condition))
         (failed-path (ignore-errors (save-failed-lisp-source resolved failed-content)))
         (rolled-back nil)
         (status nil)
         (msg nil))
    (multiple-value-bind (disk-ok mem-ok notes)
        (if rollback
            (rollback-lisp-file resolved pathname previous-good)
            (values nil nil nil))
      (setf rolled-back (and disk-ok mem-ok))
      (cond
        (rolled-back
         (setf status "已自动回滚：磁盘文件与内存定义均已恢复到「上一个可用版本」，Agent 可继续工作。"))
        ((and rollback (not (stringp previous-good)))
         (setf status "未找到回滚快照：磁盘上仍是报错版本，内存可能残留半加载定义，请尽快修复。"))
        (rollback
         (setf status (format nil "自动回滚未完全成功（~{~A~^；~}），磁盘/内存可能不一致，请立即修复。" notes)))
        (t
         (setf status "已按要求跳过回滚，磁盘上仍是报错版本。")))
      (setf msg
            (format nil "[失败] Lisp 热重载失败（已捕获，Agent Loop 继续运行）~%文件: ~A~%错误: ~A~%处理: ~A~A~%~%-> 请修复该文件后用 write_file 重新写入（务必保证括号完整、可编译）。在重载成功之前，请勿假设改动已经生效。"
                    resolved error-text status
                    (if failed-path
                        (format nil "~%失败版本已另存为: ~A" failed-path)
                        "")))
      ;; 重置 mtime，避免此后每一轮都重复尝试加载同一个坏文件
      (setf (gethash resolved *loaded-file-mtimes*)
            (or (ignore-errors (file-write-date pathname)) (get-universal-time)))
      (when record
        (record-lisp-reload-error msg))
      (unless quiet
        (format *error-output* "  ~A ~A~%      原因: ~A~%      处理: ~A~%"
                (ui-tag-err "失败") resolved error-text status))
      (values nil msg rolled-back))))

;;; ── 对外接口：热重载与自动检测 ───────────────────────

(defun hot-reload-lisp-file (filepath &key (quiet nil) (rollback t) (record nil))
  "在当前运行的 SBCL 镜像中立即热加载指定的 .lisp 文件（无需重启进程）。
失败时自动回滚到上一个可用版本，并把错误作为返回值交还调用方，绝不抛异常打断任务。
返回 (values 成功-p 消息 &optional 已回滚-p)。"
  (let* ((resolved (resolve-path filepath))
         (pathname (native-file-pathname resolved)))
    (if (not (uiop:file-exists-p pathname))
        (let ((m (format nil "文件不存在: ~A" resolved)))
          (when record
            (record-lisp-reload-error (format nil "[失败] Lisp 热重载失败: ~A" m)))
          (values nil m nil))
        (let ((disk-content (safe-read-file-content pathname))
              (previous-good (gethash resolved *lisp-file-backups*)))
          (handler-case
              (progn
                (load-lisp-file-quietly pathname)
                ;; 冒烟自检：拦截编译通过但运行期必崩的核心缺陷（如不支持的 curl 参数）
                (smoke-test-reloaded-file resolved disk-content)
                ;; 若文件较上一版发生了修改，先把改动前的可用版本存入「待验证备份表」，
                ;; 等下一轮 LLM 请求真正成功返回后再由 commit-verified-lisp-backups 确认。
                (when (and (stringp previous-good)
                           (stringp disk-content)
                           (not (string= previous-good disk-content))
                           (null (gethash resolved *lisp-unverified-backups*)))
                  (setf (gethash resolved *lisp-unverified-backups*) previous-good))
                ;; 加载与冒烟自检通过 → 更新当前快照
                (when (stringp disk-content)
                  (setf (gethash resolved *lisp-file-backups*) disk-content))
                (setf (gethash resolved *loaded-file-mtimes*)
                      (or (ignore-errors (file-write-date pathname))
                          (get-universal-time)))
                (unless quiet
                  (format t "  ~A Lisp 热重载已生效: ~A~%" (ui-tag-ok "重载") resolved))
                (values t (format nil "热重载成功: ~A" resolved) nil))
            (serious-condition (e)
              (handle-reload-failure resolved pathname e disk-content previous-good
                                     rollback record quiet)))))))

(defun check-and-hot-reload-modified-files ()
  "扫描核心 .lisp 文件，若磁盘上有更新则立即热重载。
失败时自动回滚，并把错误放入待注入队列供 agent-loop 注入给 LLM；本函数永不抛异常。
返回 (values 已重载列表 失败消息列表)。"
  (let ((reloaded nil)
        (failures nil))
    (dolist (rel *core-lisp-files*)
      (ignore-errors
        (let* ((resolved (resolve-path rel))
               (pathname (native-file-pathname resolved)))
          (when (uiop:file-exists-p pathname)
            (let ((disk-mtime (ignore-errors (file-write-date pathname)))
                  (last-mtime (gethash resolved *loaded-file-mtimes*)))
              (when (and disk-mtime
                         (or (null last-mtime) (> disk-mtime last-mtime)))
                (multiple-value-bind (ok msg rolled-back)
                    (hot-reload-lisp-file resolved
                                          :quiet (null last-mtime)
                                          :record (not (null last-mtime)))
                  (declare (ignore rolled-back))
                  (if ok
                      (when last-mtime (push resolved reloaded))
                      (when last-mtime (push msg failures))))))))))
    (values (nreverse reloaded) (nreverse failures))))
