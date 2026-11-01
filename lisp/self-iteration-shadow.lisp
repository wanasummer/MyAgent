;;;; lisp/self-iteration-shadow.lisp
;;;; 自省子 Agent 的影子克隆流程：
;;;;   分析 -> 在轻量克隆里落地建议改动 -> 克隆内编译 + 全量加载验证
;;;;   -> 主进程空闲时合并 -> 失败立即回滚。
;;;;
;;;; 定位：面向 24 小时无人值守的自迭代。行动上更激进（默认开启、自动合并），
;;;;       但「是否实行」的判定非常严格（白名单 + 小改动 + 危险片段拦截 + 独立进程全量加载验证）。
;;;;
;;;; 安全边界：
;;;;   1. 克隆只复制 lisp/*.lisp 与 run.lisp，放在 .myagent/shadow/<时间戳>/，与主版本隔离；
;;;;   2. 安全关键文件（热重载引擎、文件底层、本模块自身、run.lisp、.env）禁止自动改动；
;;;;   3. 改动必须是小范围的唯一精确替换，且不得包含退出进程、删目录、读密钥等危险片段；
;;;;   4. 验证必须在独立 SBCL 进程里完整加载全部模块成功，才允许合并；
;;;;   5. 合并前确认主进程不忙且空闲 >=5 秒；合并后逐个热重载，失败用原始内容回滚；
;;;;   6. 用户中途退出：克隆留在磁盘但不合并，按 1 天超时清理，主版本不受影响。

(in-package :cl-user)

(defparameter *self-iteration-shadow-enabled*
  (self-iteration-env-flag "MYAGENT_SELF_ITERATION_SHADOW" t)
  "是否启用影子克隆模式。默认开启；设置 MYAGENT_SELF_ITERATION_SHADOW=0 可关闭。")

(defparameter *self-iteration-shadow-merge-idle-seconds* 1
  "合并前要求主进程至少空闲多少秒，避免在用户刚提交任务时热替换代码。")

(defparameter *self-iteration-shadow-max-files* 5
  "一次影子迭代最多允许改动的文件数。")

(defparameter *self-iteration-shadow-cleanup-seconds* 86400
  "影子目录超过该秒数（默认 1 天）未合并则自动清理。")

(defparameter *self-iteration-protected-files* nil
  "不再保护特定文件：任意 lisp 代码都可被影子迭代修改，靠验证、合并回滚与启动恢复兜底。")

(defparameter *self-iteration-shadow-forbidden-snippets* nil
  "不设片段门禁；只保留 .env 文件本身不允许改。")

(defvar *self-iteration-shadow-paused-until* 0
  "影子迭代连续失败后的冷却截止时间（universal time）；到点自动恢复，无需手动开启。")

(defvar *self-iteration-shadow-state* :idle
  "影子流程状态：:idle / :building / :verifying / :pending-merge / :merging / :rejected。")

(defvar *self-iteration-pending-merge* nil
  "等待空闲后合并的改动：(:dir 克隆目录 :files ((相对路径 . 原始内容) ...) :finding 说明)。")

(defun self-iteration-shadow-root ()
  "影子克隆根目录（项目根下的 .myagent/shadow）。"
  (resolve-path (format nil "~A/.myagent/shadow" (resolve-path "."))))

(defun self-iteration-shadow-cleanup ()
  "清理超时的影子目录：用户中途退出留下的克隆直接丢弃。"
  (let ((root (self-iteration-shadow-root)))
    (when (uiop:file-exists-p (native-file-pathname root))
      (dolist (d (ignore-errors (uiop:subdirectories (uiop:ensure-directory-pathname root))))
        (let ((mt (ignore-errors (file-write-date d))))
          (when (and mt
                     (> (- (get-universal-time) mt) *self-iteration-shadow-cleanup-seconds*))
            (ignore-errors (uiop:delete-directory-tree d :validate t)))))))
  t)

(defun self-iteration-shadow-create ()
  "基于当前主版本创建轻量克隆，返回克隆目录字符串。"
  (let* ((stamp (format nil "~D-~D" (get-universal-time) (random 1000000)))
         (dir (format nil "~A/~A" (self-iteration-shadow-root) stamp))
         (files (append *core-lisp-files* '("run.lisp"))))
    (ensure-directories-exist (native-file-pathname (format nil "~A/x" dir)))
    (dolist (rel files)
      (let ((src (ignore-errors (resolve-path rel))))
        (when (and src (uiop:file-exists-p (native-file-pathname src)))
          (let ((dst (format nil "~A/~A" dir rel)))
            (ensure-directories-exist (native-file-pathname dst))
            (ignore-errors (uiop:copy-file (native-file-pathname src)
                                           (native-file-pathname dst)))))))
    dir))

(defun self-iteration-shadow-edit-allowed-p (edit)
  "不设策略门禁：任何文件都可改，仅 .env 例外（避免密钥泄露）。"
  (let ((file (getf edit :file)))
    (and (stringp file)
         (not (string-equal file ".env")))))

(defun self-iteration-shadow-apply-edit (dir edit)
  "把「精确替换」应用到克隆里；成功返回被改动的相对路径列表，失败返回 nil。"
  (let* ((rel (getf edit :file))
         (find-text (getf edit :find))
         (replace-text (getf edit :replace))
         (src (and rel (format nil "~A/~A" dir rel)))
         (text (and src (ignore-errors
                          (uiop:read-file-string (native-file-pathname src)
                                                 :external-format :utf-8)))))
    (when (and (stringp text) (stringp find-text) (plusp (length find-text))
               (stringp replace-text))
      (let* ((pos (search find-text text))
             (next (and pos (search find-text text :start2 (+ pos (length find-text))))))
        (when (and pos (null next))
          (let ((new (concatenate 'string
                                  (subseq text 0 pos)
                                  replace-text
                                  (subseq text (+ pos (length find-text))))))
            (when (myagent-atomic-write src new)
              (list rel))))))))

(defun self-iteration-sbcl-executable ()
  "用于独立验证的 SBCL 可执行文件；可用 MYAGENT_SBCL 覆盖。"
  (or (and (fboundp 'get-env) (ignore-errors (get-env "MYAGENT_SBCL")))
      #+win32 "sbcl.exe"
      #-win32 "sbcl"))

(defun self-iteration-shadow-verify-full-load (dir)
  "在独立 SBCL 进程里完整加载克隆的全部模块；成功返回 t。
这是「是否实行」的硬门禁：编译通过还不够，必须整包加载不报错。"
  (let* ((harness (format nil "~A/verify-all.lisp" dir))
         (body (format nil "(require :asdf)~%(setf *load-verbose* nil *load-print* nil)~%(let ((base (uiop:pathname-directory-pathname *load-truename*)))~%  (handler-case~%      (progn~%        (dolist (f '~S) (load (merge-pathnames f base) :external-format :utf-8))~%        (format t \"VERIFY-OK~~%\")~%        (uiop:quit 0))~%    (error (e) (format t \"VERIFY-FAIL: ~~A~~%\" e) (uiop:quit 2))))~%"
                       *core-lisp-files*)))
    (myagent-write-file-direct harness body)
    (handler-case
        (multiple-value-bind (out err code)
            (uiop:run-program (list (self-iteration-sbcl-executable)
                                    "--noinform" "--non-interactive"
                                    "--load" (uiop:native-namestring (native-file-pathname harness)))
                              :output :string :error-output :string
                              :ignore-error-status t)
          (declare (ignore err))
          (and (eql code 0) (search "VERIFY-OK" out) t))
      (error () nil))))

(defun self-iteration-shadow-verify (dir files)
  "先逐个编译改动文件，再在独立进程里完整加载全部模块；两步都通过才算验证成功。"
  (let ((ok t))
    (dolist (rel files)
      (let* ((path (format nil "~A/~A" dir rel))
             (fasl (format nil "~A.verify.fasl" path)))
        (multiple-value-bind (out warn fail)
            (let ((*compile-verbose* nil)
                  (*compile-print* nil))
              (handler-case
                  (compile-file (native-file-pathname path)
                                :output-file (native-file-pathname fasl))
                (error (e)
                  (declare (ignore e))
                  (values nil nil t))))
          (declare (ignore out warn))
          (when (or fail (not (uiop:file-exists-p (native-file-pathname fasl))))
            (setf ok nil))
          (ignore-errors (delete-file (native-file-pathname fasl))))))
    (and ok (self-iteration-shadow-verify-full-load dir))))

(defparameter *self-iteration-shadow-system-prompt*
  "你是 MyAgent 的影子迭代子 Agent。首要任务：结合「最近用户需求」与「最近交互信号」，判断最近几轮主进程对话中的需求是否真正完成、哪里可以优化（需求理解、协作流程、遗漏实现）；其次分析 Agent 可扩展 / 可优化的点。你输出的 edit 可以修改任意 lisp 代码（含核心模块），系统会自动做克隆验证、空闲合并与失败回滚。
只输出一个 JSON 对象，字段：（硬性规则：若最近交互信号中存在用户多次纠正、但尚未落到 cli.lisp 或 ui.lisp 渲染代码的需求，本轮 edit 必须直接修改对应渲染代码，禁止只改文档或记忆来交差；该需求算完成后才能换别的优化点）
finding（问题一句话）、summary（不超过 30 字、给 CLI 显示的一句话总结）、category（robustness|performance|tooling|ux|docs|hygiene|collaboration）、
priority（low|medium|high）、suggestion（一句话改法）、
edit（必填对象：{\"file\":\"lisp/xxx.lisp\",\"find\":\"克隆里必须唯一的原文片段\",\"replace\":\"替换后的片段\"}）。
约束：
1. edit 可以指向任意 lisp/*.lisp（含 cli / agent-loop / tools / reload-engine）、run.lisp 或 Agents.md；find 必须是文件中只出现一次的精确子串，长度至少 8 字符；
2. 一次最多改一个文件，替换文本不超过 8000 字符；
3. 不要改 .env、不要泄露密钥；允许修改核心代码，验证与回滚会自动兜底；
4. 每轮必须给出 edit：选一个真实、具体、最小可落地的代码或规则改动；禁止只分析不修改；
5. 全部中文，禁止 emoji 与 Markdown 代码块。"
  "影子迭代的系统提示词。")

(defun self-iteration-shadow-consult (facts)
  "调用一次轻量 LLM，返回 (:finding ... :category ... :priority ... :suggestion ... :edit ...)。"
  (let* ((*stream-enabled* nil)
         (*stream-output-started* nil)
         (*default-max-output-tokens* 4000)
         (*http-max-time* *self-iteration-request-timeout*)
         (*http-connect-timeout* "8")
         (*http-max-attempts* 1)
         (resp (funcall 'chat-with-tools
                        :system *self-iteration-shadow-system-prompt*
                        :messages (list (jobj "role" "user"
                                              "content" (format nil "项目事实：~%~A~%~%请给出唯一 JSON 结论。" facts)))
                        :tools nil)))
    (when (hash-table-p resp)
      (let* ((text (funcall 'collect-answer-text (jget resp "content")))
             (obj (self-iteration-extract-json text))
             (edit (and (hash-table-p obj) (jget obj "edit"))))
        (when (hash-table-p obj)
          (list :finding (or (jget obj "finding") "暂无明显改进点")
                :summary (jget obj "summary")
                :category (or (jget obj "category") "hygiene")
                :priority (or (jget obj "priority") "low")
                :suggestion (or (jget obj "suggestion") "")
                :edit (and (hash-table-p edit)
                           (list :file (jget edit "file")
                                 :find (jget edit "find")
                                 :replace (jget edit "replace")))))))))

(defun self-iteration-shadow-merge (pending)
  "主进程空闲时把克隆改动合并回主版本；失败立即用原始内容回滚。
返回 t（已合并）/ :deferred（等空闲）/ :rejected（失败已回滚）。"
  (if (or *self-iteration-main-busy*
          (< (self-iteration-idle-seconds-now) *self-iteration-shadow-merge-idle-seconds*)
          (and (boundp '*pending-lisp-reload-errors*) *pending-lisp-reload-errors*))
      (progn (setf *self-iteration-shadow-state* :pending-merge) :deferred)
      (progn
        (setf *self-iteration-shadow-state* :merging)
        (let* ((dir (getf pending :dir))
               (files (getf pending :files))
               (ok t))
          (dolist (pair files)
            (let* ((rel (car pair))
                   (src (format nil "~A/~A" dir rel))
                   (text (ignore-errors
                           (uiop:read-file-string (native-file-pathname src)
                                                  :external-format :utf-8))))
              (unless (and text (myagent-atomic-write (resolve-path rel) text))
                (setf ok nil))))
          (when ok
            (dolist (pair files)
              (multiple-value-bind (rok rmsg rolled)
                  (if (and (>= (length (car pair)) 5)
                           (string-equal ".lisp" (subseq (car pair) (- (length (car pair)) 5))))
                      (hot-reload-lisp-file (resolve-path (car pair)))
                      (values t "非 Lisp 文件，跳过热重载" nil))
                (declare (ignore rolled))
                (unless rok
                  (setf ok nil)
                  (format t "  [影子] 合并后热重载失败: ~A~%" rmsg)))))
          (unless ok
            (dolist (pair files)
              (ignore-errors (myagent-atomic-write (resolve-path (car pair)) (cdr pair)))
              (ignore-errors (hot-reload-lisp-file (resolve-path (car pair))))))
          (ignore-errors (uiop:delete-directory-tree
                          (uiop:ensure-directory-pathname dir) :validate t))
          (setf *self-iteration-pending-merge* nil
                *self-iteration-shadow-state* (if ok :idle :rejected))
          (if ok t :rejected)))))

(defun self-iteration-shadow-consult-feasibility (edit)
  "轻量 LLM 可行性复核：只输出 JSON {feasible,reason,risk}。"
  (let* ((*stream-enabled* nil)
         (*stream-output-started* nil)
         (*default-max-output-tokens* 200)
         (*http-max-time* *self-iteration-request-timeout*)
         (*http-connect-timeout* "8")
         (*http-max-attempts* 1)
         (prompt (format nil "判断下面这个代码改动是否可行、是否会导致明显回归。只输出 JSON：{\"feasible\": true|false, \"reason\": \"一句话\", \"risk\": \"low|medium|high\"}。~%文件: ~A~%原文片段: ~A~%替换为: ~A"
                         (getf edit :file) (getf edit :find) (getf edit :replace)))
         (resp (funcall 'chat-with-tools
                        :system "你是严格的代码评审，只输出 JSON。"
                        :messages (list (jobj "role" "user" "content" prompt))
                        :tools nil)))
    (when (hash-table-p resp)
      (let* ((text (funcall 'collect-answer-text (jget resp "content")))
             (obj (self-iteration-extract-json text)))
        (when (hash-table-p obj)
          (values (jtrue-p (jget obj "feasible"))
                  (or (jget obj "reason") "")
                  (or (jget obj "risk") "medium")))))))

(defun self-iteration-shadow-feasibility (edit)
  "不设 LLM 可行性复核：字段完整即可行。返回 (values 可行 原因 风险)。"
  (let ((ok (and (stringp (getf edit :file))
                 (stringp (getf edit :find))
                 (plusp (length (getf edit :find)))
                 (stringp (getf edit :replace)))))
    (values ok (if ok "通过" "字段不完整") "low")))

(defun self-iteration-shadow-child-execute (dir edit)
  "把改动交给独立 SBCL 子进程执行（在克隆目录内），成功返回改动文件列表。"
  (let* ((rel (getf edit :file))
         (script (format nil "~A/do-edit.lisp" dir))
         (body (format nil "(require :asdf)~%(let* ((base (uiop:pathname-directory-pathname *load-truename*))~%       (file (merge-pathnames ~S base))~%       (find ~S)~%       (repl ~S)~%       (text (uiop:read-file-string file :external-format :utf-8))~%       (pos (search find text)))~%  (unless pos (format t \"EDIT-FAIL: find not found~~%\") (uiop:quit 2))~%  (when (search find text :start2 (1+ pos)) (format t \"EDIT-FAIL: ambiguous~~%\") (uiop:quit 3))~%  (with-open-file (out file :direction :output :if-exists :supersede :external-format :utf-8)~%    (write-string (concatenate 'string (subseq text 0 pos) repl (subseq text (+ pos (length find)))) out))~%  (format t \"EDIT-OK~~%\")~%  (finish-output)~%  (uiop:quit 0))~%"
                       rel (getf edit :find) (getf edit :replace))))
    (myagent-write-file-direct script body)
    (multiple-value-bind (out err code)
        (uiop:run-program (list (self-iteration-sbcl-executable)
                                "--noinform" "--script"
                                (uiop:native-namestring (native-file-pathname script)))
                          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore err))
      (when (and (eql code 0) (search "EDIT-OK" out))
        (list rel)))))

(defun run-self-iteration-shadow-cycle (&key (reason "空闲"))
  "影子迭代一轮：分析 -> 策略门禁 -> 可行性判断 -> 克隆 -> 子进程执行 -> 双重验证 -> 空闲合并。"
  (when *self-iteration-busy*
    (return-from run-self-iteration-shadow-cycle nil))
  (setf *self-iteration-busy* t)
  (unwind-protect
       (handler-case
           (let* ((facts (self-iteration-facts-string))
                  (parsed (self-iteration-shadow-consult facts))
                  (feas (and (getf parsed :edit)
                             (multiple-value-list
                              (self-iteration-shadow-feasibility (getf parsed :edit))))))
             (when (null (getf parsed :edit))
               (setf parsed
                     (self-iteration-shadow-consult
                      (concatenate 'string facts
                                   "~%注意：上一轮没有给出 edit。必须给出 edit 字段，做一个具体的最小改动。"))))
             (setf *self-iteration-last-cycle* (get-universal-time))
             (incf *self-iteration-cycles*)
             (self-iteration-record-cycle!)
             (cond
               ((null parsed)
                (incf *self-iteration-failures*)
                (setf *self-iteration-shadow-state* :rejected)
                (self-iteration-append-log
                 (format nil "## ~A · 自省失败（影子·模型无有效结论）~%- 原因: 模型返回空或 JSON 解析失败~%- 连续失败: ~D 次~%"
                         (self-iteration-timestamp) *self-iteration-failures*))
                (when (>= *self-iteration-failures* *self-iteration-max-failures*)
                  (setf *self-iteration-failures* 0))
                (list :ok nil :message "影子迭代未获得有效结论"))
               ((and (getf parsed :edit)
                     (not (self-iteration-shadow-edit-allowed-p (getf parsed :edit))))
                (setf *self-iteration-failures* 0
                      *self-iteration-shadow-state* :rejected)
                (self-iteration-append-log
                 (self-iteration-format-entry (getf parsed :finding)
                                              (getf parsed :category)
                                              (getf parsed :priority)
                                              (getf parsed :suggestion)
                                              (format nil "~A·策略门禁拒绝" reason)))
                (list :ok nil :message "改动未通过策略门禁"))
               ((and feas (not (first feas)))
                (setf *self-iteration-failures* 0
                      *self-iteration-shadow-state* :rejected)
                (self-iteration-append-log
                 (self-iteration-format-entry (getf parsed :finding)
                                              (getf parsed :category)
                                              (getf parsed :priority)
                                              (getf parsed :suggestion)
                                              (format nil "~A·可行性拒绝：~A" reason (or (second feas) ""))))
                (list :ok nil :message "改动不可行"))
               ((null (getf parsed :edit))
                (setf *self-iteration-failures* 0
                      *self-iteration-shadow-state* :idle)
                (self-iteration-append-log
                 (self-iteration-format-entry (getf parsed :finding)
                                              (getf parsed :category)
                                              (getf parsed :priority)
                                              (getf parsed :suggestion)
                                              (format nil "~A·仅分析" reason)))
                (list :ok t :message "影子迭代完成，无改动"))
               (t
                (setf *self-iteration-shadow-state* :building)
                (let* ((dir (self-iteration-shadow-create))
                       (changed (progn
                                  (setf *self-iteration-shadow-state* :verifying)
                                  (self-iteration-shadow-child-execute dir (getf parsed :edit)))))
                  (cond
                    ((null changed)
                     (ignore-errors (uiop:delete-directory-tree
                                     (uiop:ensure-directory-pathname dir) :validate t))
                     (setf *self-iteration-shadow-state* :rejected
                           *self-iteration-failures* 0)
                     (list :ok nil :message "建议改动无法精确应用，已丢弃克隆"))
                    ((> (length changed) *self-iteration-shadow-max-files*)
                     (ignore-errors (uiop:delete-directory-tree
                                     (uiop:ensure-directory-pathname dir) :validate t))
                     (setf *self-iteration-shadow-state* :rejected)
                     (list :ok nil :message "改动文件过多，已丢弃克隆"))
                    ((not (self-iteration-shadow-verify dir changed))
                     (ignore-errors (uiop:delete-directory-tree
                                     (uiop:ensure-directory-pathname dir) :validate t))
                     (setf *self-iteration-shadow-state* :rejected
                           *self-iteration-failures* 0)
                     (list :ok nil :message "克隆验证失败，已丢弃"))
                    (t
                     (let ((files (mapcar
                                   (lambda (rel)
                                     (cons rel
                                           (ignore-errors
                                             (uiop:read-file-string
                                              (native-file-pathname (resolve-path rel))
                                              :external-format :utf-8))))
                                   changed)))
                       (setf *self-iteration-pending-merge*
                             (list :dir dir :files files :finding (getf parsed :finding)))
                       (let ((merged (self-iteration-shadow-merge *self-iteration-pending-merge*)))
                         (cond
                           ((eq merged t)
                            (self-iteration-append-log
                             (self-iteration-format-entry (getf parsed :finding)
                                                          (getf parsed :category)
                                                          (getf parsed :priority)
                                                          (getf parsed :suggestion)
                                                          (format nil "~A·已合并" reason)))
                            (self-iteration-enqueue-notice
                             (format nil "#~D 已合并 ~{~A~^, ~}"
                                     *self-iteration-cycles* changed))
                            (list :ok t :message "影子迭代已合并"))
                           ((eq merged :deferred)
                            (self-iteration-enqueue-notice
                             (format nil "#~D 已验证，待空闲合并" *self-iteration-cycles*))
                            (list :ok t :message "等待空闲合并"))
                           (t
                            (self-iteration-enqueue-notice
                             (format nil "#~D 合并失败，已回滚" *self-iteration-cycles*))
                            (list :ok nil :message "合并失败已回滚")))))))))))
         (serious-condition (e)
           (push (format nil "~A ~A" (self-iteration-timestamp) e)
                 *self-iteration-error-log*)
           (setf *self-iteration-shadow-state* :rejected)
           (list :ok nil :message (format nil "影子迭代失败: ~A" e))))
    (setf *self-iteration-busy* nil)))

(defun self-iteration-shadow-due-p ()
  "是否到了可以执行影子迭代的时机（含待合并重试）。"
  (and *self-iteration-shadow-enabled*
       (not *self-iteration-busy*)
       (not *self-iteration-main-busy*)
       (self-iteration-quota-ok-p)
       (>= (self-iteration-idle-seconds-now) *self-iteration-idle-seconds*)
       (or *self-iteration-pending-merge*
           (null *self-iteration-last-cycle*)
           (>= (- (get-universal-time) *self-iteration-last-cycle*)
               *self-iteration-interval-seconds*))))

(defun self-iteration-shadow-tick ()
  "后台心跳：有待合并就先尝试合并，否则按条件发起新一轮影子迭代。"
  (cond
    ((and *self-iteration-pending-merge* (not *self-iteration-main-busy*))
     (self-iteration-shadow-merge *self-iteration-pending-merge*))
    ((self-iteration-shadow-due-p)
     (run-self-iteration-shadow-cycle :reason "空闲"))
    (t nil)))
