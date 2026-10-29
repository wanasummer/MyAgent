;;;; lisp/reload-engine.lisp
;;;; 🔁 安全热重载引擎：失败自动回滚到「上一步」+ 错误回传给 Agent，任务不中断。
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
  "resolved path -> 上一次成功加载的源码文本，用于失败回滚（上一步快照）。")

(defvar *pending-lisp-reload-errors* nil
  "待注入给 LLM 的热重载失败信息队列（外部修改触发的自动重载失败时写入）。")

(defparameter *max-pending-reload-errors* 10
  "待注入错误队列的最大长度。")

(defparameter *core-lisp-files*
  '("lisp/reload-engine.lisp"
    "lisp/json.lisp"
    "lisp/config.lisp"
    "lisp/file-utils.lisp"
    "lisp/markdown.lisp"
    "lisp/llm-client.lisp"
    "lisp/tools.lisp"
    "lisp/agent-loop.lisp"
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

(defun pending-lisp-reload-errors-p ()
  "是否存在尚未注入给 LLM 的热重载错误。"
  (and *pending-lisp-reload-errors* t))

;;; ── 基础读写与静默加载 ───────────────────────────────

(defun safe-read-file-content (pathname)
  "读取文件文本内容，失败返回 nil。"
  (ignore-errors (uiop:read-file-string pathname :external-format :utf-8)))

(defun safe-write-file-content (pathname content)
  "把字符串安全写入文件（自动创建父目录），成功返回 t。"
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
      (format *error-output* "  ❌ 写入失败 (~A): ~A~%"
              (ignore-errors (uiop:native-namestring pathname)) e)
      nil)))

(defun load-lisp-file-quietly (pathname)
  "静默加载一个 .lisp 文件；出错则抛出条件交由调用方处理。"
  (let ((*load-verbose* nil)
        (*load-print* nil)
        #+sbcl (sb-ext:*muffled-warnings* 'style-warning))
    (load pathname :external-format :utf-8))
  t)

;;; ── 快照、失败转储与回滚 ─────────────────────────────

(defun snapshot-lisp-source! (resolved pathname)
  "把磁盘上的当前版本登记为「上一个可用版本」快照。"
  (let ((content (safe-read-file-content pathname)))
    (when (stringp content)
      (setf (gethash resolved *lisp-file-backups*) content)))
  t)

(defun seed-lisp-backups ()
  "为尚未建立快照的核心模块从磁盘补一份初始快照（只补空缺，不覆盖已有）。"
  (dolist (rel *core-lisp-files*)
    (ignore-errors
      (let* ((resolved (resolve-path rel))
             (pathname (native-file-pathname resolved)))
        (when (and (uiop:file-exists-p pathname)
                   (null (gethash resolved *lisp-file-backups*)))
          (snapshot-lisp-source! resolved pathname)))))
  t)

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
            (format nil "⚠️ Lisp 热重载失败（已捕获，Agent Loop 继续运行）~%文件: ~A~%错误: ~A~%处理: ~A~A~%~%👉 请修复该文件后用 write_file 重新写入（务必保证括号完整、可编译）。在重载成功之前，请勿假设改动已经生效。"
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
        (format *error-output* "  ⚠️ [Lisp 热重载失败] ~A~%    原因: ~A~%    ~A~%"
                resolved error-text status))
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
            (record-lisp-reload-error (format nil "⚠️ Lisp 热重载失败: ~A" m)))
          (values nil m nil))
        (let ((disk-content (safe-read-file-content pathname))
              (previous-good (gethash resolved *lisp-file-backups*)))
          (handler-case
              (progn
                (load-lisp-file-quietly pathname)
                ;; 加载成功 → 把这一版登记为上一步快照
                (when (stringp disk-content)
                  (setf (gethash resolved *lisp-file-backups*) disk-content))
                (setf (gethash resolved *loaded-file-mtimes*)
                      (or (ignore-errors (file-write-date pathname))
                          (get-universal-time)))
                (unless quiet
                  (format t "  🔥 [Lisp 热重载] 已即时加载生效: ~A~%" resolved))
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
