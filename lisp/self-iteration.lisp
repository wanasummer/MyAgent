;;;; lisp/self-iteration.lisp
;;;; 自监管迭代子 Agent (Self-Iteration SubAgent)
;;;;
;;;; 设计目标：
;;;;   1. 在「没有用户需求」的空闲期，由后台线程低频率地做一次自省体检；
;;;;   2. 自省过程不回显到终端（不打断 CLI 输入渲染），只把结论写进日志与待办清单；
;;;;   3. 下一次用户回到 CLI 时，用一行简短提示告知「发现了什么、更新了什么」；
;;;;   4. 全程受开关、频率上限、失败熔断与 API Key 检测保护，绝不阻塞前台任务；
;;;;   5. 默认只做「分析 + 记录」，不自动改代码；代码级改动仍交由主 Agent/用户确认。
;;;;
;;;; 与 supervisor.lisp 的区别：
;;;;   - supervisor 是运行期「死循环/卡死」的事中督导（毫秒级干预）；
;;;;   - self-iteration 是空闲期「可迭代项」的事后审视（分钟级、低频率、只读分析）。

(in-package :cl-user)

;;; ── 环境变量与基础辅助 ───────────────────────────────

(defun self-iteration-env-flag (name &optional default)
  "读取布尔型环境变量：0/false/off/no 视为关闭，其余非空值视为开启，未设置返回 DEFAULT。"
  (let ((v (and (fboundp 'get-env) (ignore-errors (get-env name)))))
    (cond
      ((or (null v) (zerop (length (trim-whitespace v)))) default)
      ((member (string-downcase (trim-whitespace v))
               '("0" "false" "off" "no") :test #'string=)
       nil)
      (t t))))

(defvar *self-iteration-lock*
  #+sb-thread (sb-thread:make-mutex :name "myagent-self-iteration-lock")
  #-sb-thread nil
  "后台线程与主线程共享状态（提示队列、busy 标志）的互斥锁。")

(defmacro self-iteration-with-lock (&body body)
  "在自省模块互斥锁内执行 BODY（无线程实现时直接执行）。"
  #+sb-thread `(sb-thread:with-mutex (*self-iteration-lock*) ,@body)
  #-sb-thread `(progn ,@body))

(defun self-iteration-truncate (text limit)
  "把 TEXT 截断到 LIMIT 个字符，超出时补省略号。"
  (cond
    ((null text) "")
    ((<= (length text) limit) text)
    (t (format nil "~A…" (subseq text 0 (max 0 (- limit 1)))))))

(defun self-iteration-timestamp ()
  "返回本地时间字符串：YYYY-MM-DD HH:MM:SS。"
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

;;; ── 配置 ─────────────────────────────────────────────

(defparameter *self-iteration-enabled*
  (self-iteration-env-flag "MYAGENT_SELF_ITERATION" t)
  "是否启用自监管迭代子 Agent。可用环境变量 MYAGENT_SELF_ITERATION=0 关闭。")

(defparameter *self-iteration-idle-seconds* 2
  "用户最后一次操作后，至少空闲多少秒才开始自省（默认 8 分钟）。")

(defparameter *self-iteration-interval-seconds* 300
  "两次自省之间的最小间隔秒数（默认 30 分钟，保证低频率）。")

(defparameter *self-iteration-poll-seconds* 20
  "后台线程的轮询间隔秒数（只做时间判断，不消耗网络与 token）。")

(defparameter *self-iteration-max-cycles* 6
  "单个会话内最多执行的自省次数，避免长时间挂机持续烧 token。")

(defparameter *self-iteration-max-failures* 3
  "连续失败多少次后自动暂停自省，防止反复报错刷屏。")

(defparameter *self-iteration-max-output-tokens* 420
  "自省子 Agent 单次响应的输出 token 上限（只要一个 JSON 结论）。")

(defparameter *self-iteration-request-timeout* "60"
  "自省请求的 curl 总超时秒数，避免后台请求长期占用。")

(defparameter *self-iteration-log-relative-path* "notes/self-iteration-log.md"
  "自省日志的相对路径（相对项目根目录）。")

(defparameter *self-iteration-backlog-relative-path* "notes/self-iteration-backlog.md"
  "自省产生的待办建议清单（相对项目根目录）。")

(defparameter *self-iteration-log-max-chars* 60000
  "自省日志超过该字符数时自动裁剪，只保留最近约 30000 字符。")

(defparameter *self-iteration-backlog-max-chars* 20000
  "待办清单超过该字符数时自动裁剪。")

;;; ── 全局状态 ─────────────────────────────────────────

(defvar *self-iteration-thread* nil
  "后台自省线程句柄。")

(defvar *self-iteration-busy* nil
  "自省周期自身是否正在运行（避免重入）。")

(defvar *self-iteration-main-busy* nil
  "前台 Agent 是否正在执行用户任务（全局标志，跨线程可见）。")

(defvar *self-iteration-last-activity* (get-universal-time)
  "用户最后一次操作的时间戳（universal-time）。")

(defvar *self-iteration-last-cycle* nil
  "上一次自省完成/尝试的时间戳。")

(defvar *self-iteration-cycles* 0
  "本会话累计执行的自省次数。")

(defvar *self-iteration-failures* 0
  "连续失败次数（成功后清零）。")

(defvar *self-iteration-notices* nil
  "待展示给用户的简短自省提示队列（由 CLI 在提示符前统一输出）。")

(defvar *self-iteration-last-tick* nil
  "后台线程最近一次心跳的时间戳（universal-time），用于证明自省线程仍在运行。")

(defvar *self-iteration-last-finding* nil
  "最近一次自省的结论字符串，供状态查询使用。")

(defvar *self-iteration-error-log* nil
  "最近几次自省失败原因（最多 5 条）。")
(defparameter *self-iteration-hourly-limit* 12
  "每小时最多执行多少轮自省（含影子迭代），用于 24 小时无人值守时控制成本与风险。")

(defparameter *self-iteration-daily-limit* 96
  "每天最多执行多少轮自省。")

(defvar *self-iteration-cycle-times* nil
  "最近自省发生的时间戳列表（universal-time），用于小时/天配额；会持久化到磁盘。")

(defun self-iteration-state-file ()
  (resolve-path (format nil "~A/.myagent/self-iteration-state.sexp" (resolve-path "."))))

(defun self-iteration-load-cycle-times ()
  (let* ((p (self-iteration-state-file))
         (text (and p (ignore-errors (uiop:read-file-string (native-file-pathname p)
                                                          :external-format :utf-8))))
         (data (and (stringp text) (ignore-errors (read-from-string text)))))
    (when (and (listp data) (listp (getf data :times)))
      (setf *self-iteration-cycle-times*
            (remove-if (lambda (ts) (> (- (get-universal-time) ts) 86400))
                       (getf data :times))))
    (when (and (listp data) (getf data :intensity))
      (ignore-errors (self-iteration-apply-intensity (getf data :intensity) :save nil)))
    t))

(defun self-iteration-save-cycle-times ()
  (ignore-errors
    (myagent-write-file-direct
     (self-iteration-state-file)
     (format nil "(:times ~S :intensity ~S)~%" *self-iteration-cycle-times* *self-iteration-intensity*)))
  t)

(defun self-iteration-record-cycle! ()
  (push (get-universal-time) *self-iteration-cycle-times*)
  (when (> (length *self-iteration-cycle-times*) 200)
    (setf *self-iteration-cycle-times*
          (subseq *self-iteration-cycle-times* 0 200)))
  (self-iteration-save-cycle-times)
  t)

(defun self-iteration-recent-count (seconds)
  (count-if (lambda (ts) (< (- (get-universal-time) ts) seconds))
            *self-iteration-cycle-times*))

(defparameter *self-iteration-intensities*
'((:low    :idle 300 :interval 3600 :hourly 2  :daily 12 :merge-idle 30)
(:medium :idle 60  :interval 1200 :hourly 8  :daily 48 :merge-idle 20)
(:high   :idle 5   :interval 0   :hourly nil :daily nil :merge-idle 5))
  "三档强度：空闲阈值 / 自省间隔 / 每小时上限 / 每天上限 / 合并前最小空闲。")

(defvar *self-iteration-intensity* :high
  "当前强度档位：:low / :medium / :high。")

(defun self-iteration-first-clause (text)
  "取文本的第一个句子/分句，作为模型没给 summary 时的兜底。"
  (let* ((s (trim-whitespace (or text "")))
         (pos (or (position #\。 s) (position #\； s)
                  (position #\， s) (position #\, s) (position #\Newline s))))
    (if (and pos (>= pos 6)) (subseq s 0 (1+ pos)) s)))

(defun self-iteration-cli-summary (parsed)
  "CLI 摘要优先使用模型给出的 summary 字段；缺失时退化为 finding 的第一个分句。"
  (let ((s (getf parsed :summary)))
    (if (and (stringp s) (plusp (length (trim-whitespace s))))
        (trim-whitespace s)
        (self-iteration-first-clause (getf parsed :finding)))))

(defun self-iteration-summary-text (status category priority summary)
  (format nil "~A #~D · ~A/~A · ~A · /self log"
          status *self-iteration-cycles*
          (or category "hygiene") (or priority "low")
          (or summary "")))

(defun self-iteration-summary-line (status parsed)
  (self-iteration-summary-text status
                               (getf parsed :category)
                               (getf parsed :priority)
                               (self-iteration-cli-summary parsed)))

(defun self-iteration-limit-label (n)
  (if n (format nil "~D" n) "不限"))

(defun self-iteration-intensity-label (&optional (level *self-iteration-intensity*))
  (case level (:low "低") (:medium "中") (t "高")))

(defun self-iteration-apply-intensity (level &key (save t))
  "切换强度档位并立即生效；SAVE 为真时写入状态文件，重启后保持。"
  (let ((params (cdr (assoc level *self-iteration-intensities*))))
    (when params
      (setf *self-iteration-intensity* level
            *self-iteration-idle-seconds* (getf params :idle)
            *self-iteration-interval-seconds* (getf params :interval)
            *self-iteration-hourly-limit* (getf params :hourly)
            *self-iteration-daily-limit* (getf params :daily))
      (when (boundp '*self-iteration-shadow-merge-idle-seconds*)
        (setf *self-iteration-shadow-merge-idle-seconds* (getf params :merge-idle)))
      (when save (ignore-errors (self-iteration-save-cycle-times)))
      t)))

(defun self-iteration-quota-ok-p ()
  (and (or (null *self-iteration-hourly-limit*)
           (< (self-iteration-recent-count 3600) *self-iteration-hourly-limit*))
       (or (null *self-iteration-daily-limit*)
           (< (self-iteration-recent-count 86400) *self-iteration-daily-limit*))))


;;; ── 路径与钥匙检测 ───────────────────────────────────

(defun self-iteration-project-path (relative)
  "把相对路径解析为项目根目录下的绝对路径。"
  (ignore-errors (resolve-path relative)))

(defun self-iteration-read-text (path)
  "读取文本文件；不存在或失败返回 nil。"
  (when (and path (uiop:file-exists-p (native-file-pathname path)))
    (ignore-errors (uiop:read-file-string (native-file-pathname path)
                                          :external-format :utf-8))))

(defun self-iteration-api-key-available-p ()
  "当前是否已配置可用的 API Key（未配置时后台自省静默跳过，不报错）。"
  (let ((config (ignore-errors (resolve-llm-config :allow-empty-key t))))
    (and config
         (let ((key (ignore-errors (llm-config-api-key config))))
           (and (stringp key) (plusp (length key)) t)))))

;;; ── 提示队列 ─────────────────────────────────────────

(defun self-iteration-enqueue-notice (text)
  "把一条简短自省提示放进队列，等待 CLI 在主线程展示。"
  (self-iteration-with-lock
    (push text *self-iteration-notices*)
    (when (> (length *self-iteration-notices*) 8)
      (setf *self-iteration-notices* (subseq *self-iteration-notices* 0 8)))
    t))

(defun self-iteration-drain-notices ()
  "取出并清空待展示提示（按产生顺序返回）。"
  (self-iteration-with-lock
    (prog1 (nreverse *self-iteration-notices*)
      (setf *self-iteration-notices* nil))))

(defun self-iteration-flush-notices ()
  "在主线程（CLI）输出待展示的自省提示。后台线程不得调用本函数。"
  (let ((items (self-iteration-drain-notices)))
    (when items
      (dolist (item items)
        (format t "~A ~A~%" (ui-tag-info "自省") item))
      (terpri)
      (finish-output))
    (length items)))

;;; ── 前后台互斥标记 ───────────────────────────────────

(defun self-iteration-begin-task ()
  "前台任务开始：标记忙碌并刷新用户活动时间。"
  (setf *self-iteration-main-busy* t)
  (setf *self-iteration-last-activity* (get-universal-time))
  t)

(defun self-iteration-end-task ()
  "前台任务结束：清除忙碌标记，并刷新活动时间（空闲从这个时刻开始计算）。"
  (setf *self-iteration-main-busy* nil)
  (setf *self-iteration-last-activity* (get-universal-time))
  t)

(defun self-iteration-note-activity (&optional label)
  "记录一次用户活动（收到输入、命令等），用于计算空闲时长。LABEL 仅用于调试。"
  (declare (ignore label))
  (setf *self-iteration-last-activity* (get-universal-time))
  t)

(defun self-iteration-idle-seconds-now ()
  "返回距上次用户活动的空闲秒数。"
  (max 0 (- (get-universal-time) *self-iteration-last-activity*)))

;;; ── 交互质量信号（分析需求理解问题用） ───────────────

(defvar *self-iteration-signals* nil
  "最近用户纠正 / 误解 / 返工信号（最新在前），供自省时分析需求理解问题。")

(defparameter *self-iteration-max-signals* 8
  "最多保留的交互信号条数。")

(defparameter *self-iteration-correction-keywords*
  '("没理解" "不理解" "不是这个意思" "理解错" "改出bug" "改坏了"
    "还原回去" "去掉" "不对" "错了" "为什么没" "重新来")
  "用户表达「你没理解 / 改坏了 / 要返工」的关键词，用于记录交互相应信号。")

(defun self-iteration-note-signal (kind text)
  "记录一条交互质量信号（kind 例如 :misunderstanding / :rework）。"
  (push (list :time (self-iteration-timestamp)
              :kind kind
              :text (self-iteration-truncate (or text "") 160))
        *self-iteration-signals*)
  (when (> (length *self-iteration-signals*) *self-iteration-max-signals*)
    (setf *self-iteration-signals* (subseq *self-iteration-signals* 0 *self-iteration-max-signals*)))
  t)

(defun self-iteration-observe-user-input (text)
  "观察用户输入：出现纠正/返工类措辞时记录信号，供下一次自省分析。"
  (when (and (stringp text)
             (some (lambda (kw) (search kw text)) *self-iteration-correction-keywords*))
    (self-iteration-note-signal :misunderstanding text))
  t)

(defun self-iteration-signals-brief ()
  "把最近信号压缩成一行文本，供事实采集与自省提示使用。"
  (if (null *self-iteration-signals*)
      "无"
      (format nil "~{~A~^ | ~}"
              (mapcar (lambda (s)
                        (format nil "[~A] ~A"
                                (if (eq (getf s :kind) :misunderstanding) "纠正" "返工")
                                (self-iteration-truncate (getf s :text) 60)))
                      (subseq *self-iteration-signals*
                              0 (min 3 (length *self-iteration-signals*)))))))

;;; ── 近期需求提取（从会话历史） ───────────────────────

(defun self-iteration-message-text (msg)
  (let ((content (and (hash-table-p msg) (jget msg "content"))))
    (cond
      ((stringp content) content)
      ((vectorp content) (self-iteration-blocks-text (coerce content 'list)))
      ((listp content) (self-iteration-blocks-text content))
      (t ""))))

(defun self-iteration-blocks-text (blocks)
  (format nil "~{~A~^ ~}"
          (loop for b in blocks
                when (and (hash-table-p b)
                          (equal (jget b "type") "text")
                          (stringp (jget b "text")))
                  collect (jget b "text"))))

(defun self-iteration-strip-env (text)
  (let* ((pos (search "</system-reminder>" text))
         (tail (if pos
                   (subseq text (+ pos (length "</system-reminder>")))
                   text))
         (sep (search "---" tail)))
    (trim-whitespace (if (and sep (< sep 12)) (subseq tail (+ sep 3)) tail))))

(defun self-iteration-recent-requirements (&optional (limit 3))
  "提取最近几条用户需求文本（去掉每轮注入的环境前缀）。"
  (when (and (boundp '*session-history*) (listp *session-history*))
    (let ((texts nil))
      (dolist (m (reverse *session-history*))
        (when (and (hash-table-p m) (equal (jget m "role") "user"))
          (let ((t2 (self-iteration-strip-env (self-iteration-message-text m))))
            (when (plusp (length (trim-whitespace t2)))
              (push (self-iteration-truncate t2 100) texts)))))
      (subseq texts 0 (min limit (length texts))))))

(defun self-iteration-requirements-brief ()
  (let ((items (self-iteration-recent-requirements 3)))
    (if items (format nil "~{~A~^ | ~}" items) "无")))

;;; ── 项目事实采集（纯本地、零 token） ─────────────────

(defun self-iteration-count-lines (path)
  "统计文本文件行数；读取失败返回 0。"
  (let ((text (self-iteration-read-text path)))
    (if (stringp text)
        (if (zerop (length text)) 0 (1+ (count #\Newline text)))
        0)))

(defun self-iteration-module-facts ()
  "返回核心模块的行数摘要字符串，例如 a.lisp(120) b.lisp(340)。"
  (let ((parts nil))
    (dolist (rel *core-lisp-files*)
      (let ((path (self-iteration-project-path rel)))
        (when (and path (uiop:file-exists-p (native-file-pathname path)))
          (push (format nil "~A(~D)"
                        (subseq rel (1+ (or (position #\/ rel :from-end t) -1)))
                        (self-iteration-count-lines path))
                parts))))
    (if parts (format nil "~{~A~^, ~}" (nreverse parts)) "（未能读取核心模块）")))

(defun self-iteration-marker-line-p (line)
  "判断一行是否包含真正的 TODO/FIXME/XXX/HACK 标记。
要求标记后紧跟冒号、空白、短横线或位于行尾，避免把描述性文字和扫描器源码本身算进去。"
  (loop for marker in '("TODO" "FIXME" "XXX" "HACK")
        thereis
        (loop with start = 0
              for pos = (search marker line :start2 start)
              while pos
              do (setf start (1+ pos))
              when (let ((next (and (< (+ pos (length marker)) (length line))
                                    (char line (+ pos (length marker))))))
                     (or (null next)
                         (member next '(#\: #\Space #\Tab #\-))))
                return t)))

(defun self-iteration-marker-scan ()
  "扫描核心源码中的 TODO/FIXME/XXX/HACK 标记，返回 (总数 位置列表)。"
  (let ((total 0) (places nil))
    (dolist (rel *core-lisp-files*)
      (let* ((path (self-iteration-project-path rel))
             (text (and path (self-iteration-read-text path))))
        (when (stringp text)
          (let ((line-no 0))
            (dolist (line (uiop:split-string text :separator '(#\Newline)))
              (incf line-no)
              (when (and (not (search "TODO / FIXME" line))
                         (not (search "TODO/FIXME/XXX/HACK" line))
                         (self-iteration-marker-line-p line))
                (incf total)
                (when (< (length places) 6)
                  (push (format nil "~A:~D" rel line-no) places))))))))
    (values total (nreverse places))))

(defun self-iteration-recent-findings (&optional (limit 3))
  "从自省日志中提取最近几条「发现」记录，避免重复建议。"
  (let* ((path (self-iteration-project-path *self-iteration-log-relative-path*))
         (text (self-iteration-read-text path))
         (found nil))
    (when (stringp text)
      (dolist (line (uiop:split-string text :separator '(#\Newline)))
        (when (and (>= (length line) 6) (search "- 发现:" line))
          (push (trim-whitespace (subseq line (length "- 发现:"))) found))))
    (subseq found 0 (min limit (length found)))))

(defun self-iteration-memory-count ()
  "统计持久化记忆条数（读不到时返回 0）。"
  (let ((dir (ignore-errors (get-memory-dir))))
    (or (and dir
             (ignore-errors
               (length (uiop:directory-files
                        (uiop:ensure-directory-pathname dir) "*.md"))))
        0)))

(defun self-iteration-facts-string ()
  "汇总一次自省所需的项目事实（紧凑文本，控制 token 消耗）。"
  (multiple-value-bind (marker-total marker-places)
      (self-iteration-marker-scan)
    (let ((pending-errors (and (boundp '*pending-lisp-reload-errors*)
                               (length *pending-lisp-reload-errors*)))
          (unverified (and (fboundp 'current-unverified-file-list)
                           (length (ignore-errors (current-unverified-file-list)))))
          (recent (self-iteration-recent-findings 3)))
      (format nil "日期: ~A~%工具数: ~D（~{~A~^, ~}）~%核心模块行数: ~A~%TODO/FIXME/XXX/HACK: ~D 处~@[（~{~A~^, ~}）~]~%未验证的热重载文件: ~A~%待注入的重载错误: ~A~%持久化记忆: ~D 条~%上次自省发现: ~A~%本会话已自省: ~D 次，连续失败: ~D 次~%最近交互信号: ~A~%最近用户需求: ~A"
              (self-iteration-timestamp)
              (length *tool-names-order*)
              *tool-names-order*
              (self-iteration-module-facts)
              marker-total
              (and marker-places (list marker-places))
              (if (and unverified (plusp unverified)) (format nil "~D 个" unverified) "无")
              (if (and pending-errors (plusp pending-errors)) (format nil "~D 条" pending-errors) "无")
              (self-iteration-memory-count)
              (if recent (format nil "~{~A~^ / ~}" recent) "无")
              *self-iteration-cycles*
              *self-iteration-failures*
              (self-iteration-signals-brief)
               (self-iteration-requirements-brief)))))

;;; ── 自省子 Agent 的 LLM 调用 ─────────────────────────

(defparameter *self-iteration-system-prompt*
  "你是 MyAgent 的「自监管迭代子 Agent」，只在宿主 Agent 空闲时做低成本的自我体检。
你的首要任务是：结合「最近用户需求」与「最近交互信号」，判断最近几轮主进程对话中的需求是否真正完成、哪些地方可以优化（需求理解、协作流程、遗漏的实现）；其次再分析 Agent 可扩展 / 可优化的点。最终给出 1 个最值得做的迭代点，并用一个 JSON 对象回答。
严格要求：
1. 只输出一个 JSON 对象，不要 Markdown 代码块，不要任何解释性前缀或后缀；
2. 字段固定为：finding（一句话问题描述）、summary（不超过 30 字、给 CLI 显示的一句话总结）、category（robustness|performance|tooling|ux|docs|hygiene|collaboration）、priority（low|medium|high）、suggestion（一句话可执行改法）、auto_safe（布尔，仅在改动只涉及文档/日志时为 true）；
3. 不要建议删除用户数据、不要建议修改 .env 或密钥、不要建议大范围重写或引入第三方依赖；
4. 若确实没有值得做的事情，finding 填「暂无明显改进点」，category 填 hygiene，priority 填 low。
5. 「最近用户需求」非空时，finding 必须优先围绕其中未完成或可优化的部分；若「最近交互信号」非空，优先分析需求理解 / 协作流程问题，category 用 collaboration。
6. 你可以建议修改任意 lisp 代码（含 cli / agent-loop / 工具层），但仍需遵守 JSON 格式与安全约束。
6. 全部使用中文，禁止 emoji。"
  "自省子 Agent 的系统提示词。")

(defun self-iteration-extract-json (text)
  "从模型输出中提取第一个 JSON 对象；失败返回 nil。"
  (when (stringp text)
    (let ((start (position #\{ text))
          (end (position #\} text :from-end t)))
      (when (and start end (> end start))
        (ignore-errors (json-decode (subseq text start (1+ end))))))))

(defun self-iteration-parse-answer (text)
  "把模型输出解析为 (:finding ... :category ... :priority ... :suggestion ... :auto-safe ...)。"
  (let ((obj (self-iteration-extract-json text)))
    (if (hash-table-p obj)
        (list :finding (or (jget obj "finding") "暂无明显改进点")
                :summary (jget obj "summary")
              :category (or (jget obj "category") "hygiene")
              :priority (or (jget obj "priority") "low")
              :suggestion (or (jget obj "suggestion") "")
              :auto-safe (jtrue-p (jget obj "auto_safe")))
        ;; JSON 解析失败时退化为纯文本结论，保证不丢信息
        (list :finding (self-iteration-truncate
                        (or (trim-whitespace (or text "")) "模型未返回有效内容") 120)
              :category "hygiene"
              :priority "low"
              :suggestion ""
              :auto-safe nil))))

(defun self-iteration-consult (facts)
  "调用一次轻量 LLM 做自省分析。
关键点：强制非流式、限制输出长度与超时、禁用重试，确保后台调用不打印、不拖慢前台。"
  (let* ((*stream-enabled* nil)
         (*stream-output-started* nil)
         (*default-max-output-tokens* *self-iteration-max-output-tokens*)
         (*http-max-time* *self-iteration-request-timeout*)
         (*http-connect-timeout* "8")
         (*http-max-attempts* 1)
         (resp (funcall 'chat-with-tools
                        :system *self-iteration-system-prompt*
                        :messages (list (jobj "role" "user"
                                              "content" (format nil "项目事实：~%~A~%~%请给出唯一的 JSON 结论。" facts)))
                        :tools nil)))
    (when (hash-table-p resp)
      (let ((text (funcall 'collect-answer-text (jget resp "content"))))
        (when (and (stringp text) (plusp (length (trim-whitespace text))))
          (self-iteration-parse-answer text))))))

;;; ── 日志与待办清单 ───────────────────────────────────

(defun self-iteration-append-text-file (path new-text max-chars keep-chars)
  "向文件追加 NEW-TEXT；超过 MAX-CHARS 时只保留尾部 KEEP-CHARS 字符。静默执行。"
  (let* ((old (or (self-iteration-read-text path) ""))
         (body (if (> (length old) max-chars)
                   (format nil "<!-- 日志已自动裁剪，仅保留最近内容 -->~%~A"
                           (subseq old (- (length old) keep-chars)))
                   old)))
    (safe-write-file-content (native-file-pathname path)
                             (format nil "~A~A~%" body new-text))))

(defun self-iteration-append-backlog (finding suggestion)
  "把值得跟进的自省建议追加到待办清单（去重）。"
  (let* ((path (self-iteration-project-path *self-iteration-backlog-relative-path*))
         (old (or (self-iteration-read-text path) "")))
    (when (and path
               (stringp suggestion)
               (plusp (length (trim-whitespace suggestion)))
               (not (search finding old :test #'char-equal)))
      (self-iteration-append-text-file
       path
       (format nil "- [ ] ~A~%      建议：~A~%" finding suggestion)
       *self-iteration-backlog-max-chars* 15000))))

;;; ── 单次自省周期 ─────────────────────────────────────

(defun self-iteration-format-entry (finding category priority suggestion reason)
  "组装写入日志的 Markdown 记录。"
  (format nil "## ~A · 自省（~A）~%- 类别: ~A / 优先级: ~A~%- 发现: ~A~%- 建议: ~A~%"
          (self-iteration-timestamp)
          reason
          category priority
          finding
          (if (plusp (length suggestion)) suggestion "（未给出具体改法）")))

(defun run-self-iteration-cycle (&key (reason "idle") (force nil))
  "执行一次自省：采集事实 -> 轻量 LLM 分析 -> 写日志/待办 -> 排队一条用户提示。
返回 plist：(:ok 布尔 :finding 字符串 :suggestion 字符串 :category 字符串 :priority 字符串 :message 字符串)。
FORCE 为真时忽略「自省进行中」判断（供 /self run 与 self_iteration 工具使用）。"
  (cond
    ((and *self-iteration-busy* (not force))
     (list :ok nil :message "已有一次自省正在进行，跳过"))
    ((and (not force) (not (self-iteration-api-key-available-p)))
     (setf *self-iteration-last-cycle* (get-universal-time))
     (list :ok nil :message "未配置 API Key，后台自省已静默跳过"))
    (t
     (setf *self-iteration-busy* t)
     (unwind-protect
          (handler-case
              (let* ((facts (self-iteration-facts-string))
                     ;; 模型偶发返回空时重试一次，避免把网络抖动当成自省失败
                     (parsed (or (self-iteration-consult facts)
                                 (progn (sleep 1)
                                        (self-iteration-consult facts)))))
                (if (null parsed)
                    (progn
                      (setf *self-iteration-failures* (1+ *self-iteration-failures*))
                      (push (format nil "~A 模型返回为空" (self-iteration-timestamp))
                            *self-iteration-error-log*)
                      (self-iteration-append-log
                       (format nil "## ~A · 自省失败（~A）~%- 原因: 模型返回为空~%- 连续失败: ~D 次~%"
                               (self-iteration-timestamp) reason *self-iteration-failures*))
                      (when (> (length *self-iteration-error-log*) 5)
                        (setf *self-iteration-error-log* (subseq *self-iteration-error-log* 0 5)))
                      (setf *self-iteration-last-cycle* (get-universal-time))
                      (list :ok nil :message "自省未获得有效结论（模型返回为空）"))
                    (let* ((finding (getf parsed :finding))
                           (category (getf parsed :category))
                           (priority (getf parsed :priority))
                           (suggestion (getf parsed :suggestion)))
                      (incf *self-iteration-cycles*)
                      (self-iteration-record-cycle!)
                      (setf *self-iteration-failures* 0)
                      (setf *self-iteration-last-cycle* (get-universal-time))
                      (setf *self-iteration-last-finding* finding)
                      (self-iteration-append-log
                       (self-iteration-format-entry finding category priority suggestion reason))
                      (when (member (string-downcase (format nil "~A" priority))
                                    '("medium" "high") :test #'string=)
                        (self-iteration-append-backlog finding suggestion))
                      (list :ok t
                            :finding finding
                            :suggestion suggestion
                            :category category
                            :priority priority
                            :message (format nil "自省完成（第 ~D 次），已写入 ~A"
                                             *self-iteration-cycles*
                                             *self-iteration-log-relative-path*)))))
            (serious-condition (e)
              (setf *self-iteration-failures* (1+ *self-iteration-failures*))
              (setf *self-iteration-last-cycle* (get-universal-time))
              (push (format nil "~A ~A" (self-iteration-timestamp) e)
                    *self-iteration-error-log*)
              (self-iteration-append-log
               (format nil "## ~A · 自省失败（~A）~%- 原因: ~A~%- 连续失败: ~D 次~%"
                       (self-iteration-timestamp) reason
                       (self-iteration-truncate (format nil "~A" e) 300)
                       *self-iteration-failures*))
              (when (> (length *self-iteration-error-log*) 5)
                (setf *self-iteration-error-log* (subseq *self-iteration-error-log* 0 5)))
              (when (>= *self-iteration-failures* *self-iteration-max-failures*)
                (setf *self-iteration-enabled* nil)
                (self-iteration-enqueue-notice
                 (format nil "连续失败 ~D 次，已自动暂停（输入 /self on 可恢复）；原因：~A"
                         *self-iteration-failures*
                         (self-iteration-truncate (format nil "~A" e) 80))))
              (list :ok nil :message (format nil "自省失败: ~A" e))))
       (setf *self-iteration-busy* nil)))))

;;; ── 后台循环 ─────────────────────────────────────────

(defun self-iteration-thread-alive-p ()
  "后台自省线程是否还活着。"
  #+sb-thread (and *self-iteration-thread*
                   (ignore-errors (sb-thread:thread-alive-p *self-iteration-thread*)))
  #-sb-thread nil)

(defun self-iteration-should-run-p ()
  "判断当前是否满足「空闲 + 未到频率上限 + 无前台任务」等自省条件。"
  (and *self-iteration-enabled*
       (not *self-iteration-busy*)
       (not *self-iteration-main-busy*)
       (self-iteration-quota-ok-p)
       (>= (self-iteration-idle-seconds-now) *self-iteration-idle-seconds*)
       (or (null *self-iteration-last-cycle*)
           (>= (- (get-universal-time) *self-iteration-last-cycle*)
               *self-iteration-interval-seconds*))
       (self-iteration-api-key-available-p)))

(defun run-self-iteration-once (&key (reason "手动"))
  "执行一次自省：只走影子模式；影子模式关闭时不执行分析。"
  (if (and (boundp '*self-iteration-shadow-enabled*)
           *self-iteration-shadow-enabled*)
      (run-self-iteration-shadow-cycle :reason reason)
      (list :ok nil :message "影子模式已关闭，未执行自省（/self shadow on 可开启）")))

(defun self-iteration-tick ()
  "后台线程的一次心跳：只走影子模式（克隆 + 验证 + 空闲合并）。影子模式关闭时什么都不做，永不抛异常。"
  (setf *self-iteration-last-tick* (get-universal-time))
  (when (and (fboundp 'self-iteration-shadow-tick)
             (boundp '*self-iteration-shadow-enabled*)
             *self-iteration-shadow-enabled*)
    (funcall 'self-iteration-shadow-tick)))

(defun self-iteration-start-thread ()
  "启动后台自省线程（幂等，重复调用不会创建第二个线程）。"
  (ignore-errors (self-iteration-load-cycle-times))
  #-sb-thread (progn *self-iteration-enabled* nil)
  #+sb-thread
  (when (and *self-iteration-enabled* (not (self-iteration-thread-alive-p)))
    (setf *self-iteration-thread*
          (sb-thread:make-thread
           (lambda ()
             (handler-case
                 (loop
                   (sleep *self-iteration-poll-seconds*)
                   (ignore-errors (funcall 'self-iteration-tick)))
               (serious-condition () nil)))
           :name "myagent-self-iteration"))
    t))

(defun self-iteration-stop-thread ()
  "停止后台自省线程（当前会话彻底关闭自省时使用）。"
  #+sb-thread
  (progn
    (when (self-iteration-thread-alive-p)
      (ignore-errors (sb-thread:terminate-thread *self-iteration-thread*)))
    (setf *self-iteration-thread* nil)
    t)
  #-sb-thread nil)

;;; ── 提示栏状态灯（供 CLI 常驻显示） ─────────────────

(defparameter *self-iteration-spinner-frames* '("|" "/" "-" "\\")
  "执行态旋转动画的帧序列（纯 ASCII，兼容任意控制台字体）。")

(defvar *self-iteration-spin-index* 0
  "当前旋转帧下标。")

(defun self-iteration-busy-p ()
  "自省子 Agent 当前是否正在执行一次分析。"
  (and *self-iteration-busy* t))

(defun self-iteration-state ()
  "返回状态关键字：:off（关闭） / :running（执行中） / :waiting（等待）。"
  (cond ((not *self-iteration-enabled*) :off)
        (*self-iteration-busy* :running)
        (t :waiting)))

(defun self-iteration-indicator ()
  "返回提示栏最右侧的状态灯文本（固定显示宽度，颜色：红=关闭 / 绿=执行 / 黄=等待）。"
  (let* ((state (self-iteration-state))
         (frames *self-iteration-spinner-frames*)
         (base (case state
                 (:off "● 自省:关闭")
                 (:running (format nil "● 自省:执行 ~A"
                                   (nth (mod *self-iteration-spin-index* (length frames)) frames)))
                 (t "● 自省:等待")))
         (color (case state (:off "1;31") (:running "1;32") (t "1;33")))
         (maxw (max (display-width* "● 自省:关闭")
                    (display-width* "● 自省:等待")
                    (display-width* "● 自省:执行 |")))
         (pad (max 0 (- maxw (display-width* base)))))
    (when (eq state :running)
      (setf *self-iteration-spin-index*
            (mod (1+ *self-iteration-spin-index*) (length frames))))
    (ui-colorize color (concatenate 'string base
                                    (make-string pad :initial-element #\Space)))))

;;; ── 状态查看与 /self 命令 ────────────────────────────

(defun self-iteration-status-lines ()
  "返回自省状态的多行说明。"
  (list
   (format nil "状态: ~A"
           (cond ((not *self-iteration-enabled*) "已暂停（/self toggle 或 /self on 恢复）")
                 ((self-iteration-thread-alive-p) "运行中（空闲时低频率自检）")
                 (t "已关闭线程（会话重启后恢复）")))
   (format nil "触发条件: 空闲 ~D 秒后启动；两次自省至少间隔 ~D 秒；每小时 ~A 次、每天 ~A 次"
           *self-iteration-idle-seconds* *self-iteration-interval-seconds*
           (self-iteration-limit-label *self-iteration-hourly-limit*) (self-iteration-limit-label *self-iteration-daily-limit*))
   (format nil "运行统计: 已自省 ~D 次 · 连续失败 ~D 次 · 当前空闲 ~D 秒"
           *self-iteration-cycles* *self-iteration-failures*
           (self-iteration-idle-seconds-now))
   (format nil "心跳: ~A · 下次最早 ~D 秒后"
           (if *self-iteration-last-tick*
               (format nil "~D 秒前" (- (get-universal-time) *self-iteration-last-tick*))
               "尚未开始")
           (max (max 0 (- *self-iteration-idle-seconds* (self-iteration-idle-seconds-now)))
                (if *self-iteration-last-cycle*
                    (max 0 (- *self-iteration-interval-seconds*
                              (- (get-universal-time) *self-iteration-last-cycle*)))
                    0)))
   (format nil "最近发现: ~A"
           (or *self-iteration-last-finding* "（还没有）"))
   (format nil "强度: ~A（空闲 ~D 秒 / 间隔 ~D 秒 / 每小时 ~A / 每天 ~A）"
           (self-iteration-intensity-label) *self-iteration-idle-seconds*
           *self-iteration-interval-seconds* (self-iteration-limit-label *self-iteration-hourly-limit*)
           (self-iteration-limit-label *self-iteration-daily-limit*))
   (format nil "影子模式: ~A · 状态 ~A · 待合并 ~A"
           (if (and (boundp '*self-iteration-shadow-enabled*) *self-iteration-shadow-enabled*) "开启" "关闭")
           (if (boundp '*self-iteration-shadow-state*) *self-iteration-shadow-state* :idle)
           (if (and (boundp '*self-iteration-pending-merge*) *self-iteration-pending-merge*) "有" "无"))
   (format nil "输出文件: ~A / ~A"
           *self-iteration-log-relative-path*
           *self-iteration-backlog-relative-path*)))

(defun self-iteration-tail-lines (path limit)
  "读取文件末尾 LIMIT 行（用于 /self log）。"
  (let* ((text (self-iteration-read-text path))
         (lines (and (stringp text)
                     (uiop:split-string text :separator '(#\Newline)))))
    (if lines
        (subseq lines (max 0 (- (length lines) limit)))
        '("（文件还不存在，尚未产生自省记录）"))))

(defun self-iteration-handle-command (arg)
  "处理 /self 子命令：status / on / off / run / log / backlog。"
  (let ((a (string-downcase (trim-whitespace (or arg "")))))
    (cond
      ((or (string= a "") (string= a "status"))
       (format t "~%  ~A 自监管迭代子 Agent~%" (ui-tag-info "自省"))
       (dolist (line (self-iteration-status-lines))
         (format t "    ~A~%" line))
       (when *self-iteration-error-log*
         (format t "    最近失败: ~A~%" (first *self-iteration-error-log*)))
       (terpri)
       (finish-output)
       :handled)

      ((string= a "on")
       (setf *self-iteration-enabled* t
             *self-iteration-failures* 0)
       (self-iteration-note-activity "self on")
       (self-iteration-start-thread)
       (format t "  ~A 自省子 Agent 已开启（空闲 ~D 秒后开始，最低间隔 ~D 秒）。~%~%"
               (ui-tag-ok "开启") *self-iteration-idle-seconds*
               *self-iteration-interval-seconds*)
       (finish-output)
       :handled)

      ((string= a "toggle")
       (if *self-iteration-enabled*
           (progn
             (setf *self-iteration-enabled* nil)
             (format t "  ~A 自省子 Agent 已暂停（原状态：开启；再输入 /self toggle 可恢复）。~%~%"
                     (ui-tag-info "切换")))
           (progn
             (setf *self-iteration-enabled* t
                   *self-iteration-failures* 0)
             (self-iteration-note-activity "self toggle")
             (self-iteration-start-thread)
             (format t "  ~A 自省子 Agent 已开启（原状态：暂停；空闲 ~D 秒后开始，最低间隔 ~D 秒）。~%~%"
                     (ui-tag-ok "切换") *self-iteration-idle-seconds*
                     *self-iteration-interval-seconds*)))
       (finish-output)
       :handled)

      ((string= a "off")
       (setf *self-iteration-enabled* nil)
       (format t "  ~A 自省子 Agent 已暂停（后台线程休眠，不消耗 token）。~%~%"
               (ui-tag-info "暂停"))
       (finish-output)
       :handled)

      ((string= a "run")
       (format t "  ~A 正在执行一次自省分析（会调用一次轻量 LLM，约数秒）…~%"
               (ui-tag-info "自省"))
       (finish-output)
       (let ((res (run-self-iteration-once :reason "手动")))
         (if (getf res :ok)
             (progn
               (format t "  ~A ~A~%    发现: ~A~%    建议: ~A~%    类别: ~A / 优先级: ~A~%~%"
                       (ui-tag-ok "完成")
                       (getf res :message)
                       (getf res :finding)
                       (getf res :suggestion)
                       (getf res :category)
                       (getf res :priority)))
             (format t "  ~A ~A~%~%" (ui-tag-warn "未完成") (getf res :message))))
       (finish-output)
       :handled)

      ((string= a "log")
       (let ((path (self-iteration-project-path *self-iteration-log-relative-path*)))
         (format t "~%  ~A ~A~%" (ui-tag-info "自省日志") (or path "（路径未解析）"))
         (dolist (line (self-iteration-tail-lines path 40))
           (format t "    ~A~%" line))
         (terpri)
         (finish-output)
         :handled))

      ((string= a "backlog")
       (let ((path (self-iteration-project-path *self-iteration-backlog-relative-path*)))
         (format t "~%  ~A ~A~%" (ui-tag-info "自省待办") (or path "（路径未解析）"))
         (dolist (line (self-iteration-tail-lines path 40))
           (format t "    ~A~%" line))
         (terpri)
         (finish-output)
         :handled))

      ((or (string= a "shadow")
           (and (> (length a) 7) (string-equal "shadow " (subseq a 0 7))))
       (let ((arg (trim-whitespace (subseq a 6))))
         (cond
           ((string-equal arg "on")
            (setf *self-iteration-shadow-enabled* t)
            (format t "  ~A 影子模式已开启：改动先落在 .myagent/shadow 克隆，验证通过后主进程空闲时合并。~%~%"
                    (ui-tag-ok "影子")))
           ((string-equal arg "off")
            (setf *self-iteration-shadow-enabled* nil *self-iteration-shadow-state* :idle)
            (format t "  ~A 影子模式已关闭，仅做分析。~%~%" (ui-tag-info "影子")))
           (t
            (format t "  ~A 影子模式: ~A · 状态: ~A · 待合并: ~A~%~%"
                    (ui-tag-info "影子")
                    (if *self-iteration-shadow-enabled* "开启" "关闭")
                    *self-iteration-shadow-state*
                    (if *self-iteration-pending-merge* "有" "无")))))
       (finish-output)
       :handled)

      ((or (string= a "intensity")
           (and (> (length a) 10) (string-equal "intensity " (subseq a 0 10))))
       (let ((arg (string-downcase (trim-whitespace (subseq a 9)))))
         (cond
           ((or (string= arg "") (string= arg "status"))
            (format t "  ~A 当前强度: ~A（空闲 ~D 秒 / 间隔 ~D 秒 / 每小时 ≤~D / 每天 ≤~D）~%~%"
                    (ui-tag-info "强度") (self-iteration-intensity-label)
                    *self-iteration-idle-seconds* *self-iteration-interval-seconds*
                    (self-iteration-limit-label *self-iteration-hourly-limit*)
            (self-iteration-limit-label *self-iteration-daily-limit*)))
           ((member arg '("low" "l" "低" "1") :test #'string=)
            (self-iteration-apply-intensity :low)
            (format t "  ~A 强度已切换为低档（空闲 ~D 秒 / 间隔 ~D 秒 / 每小时 ~A / 每天 ~A）~%~%"
                    (ui-tag-ok "强度") *self-iteration-idle-seconds*
                    *self-iteration-interval-seconds* (self-iteration-limit-label *self-iteration-hourly-limit*)
                    (self-iteration-limit-label *self-iteration-daily-limit*)))
           ((member arg '("medium" "m" "中" "2") :test #'string=)
            (self-iteration-apply-intensity :medium)
            (format t "  ~A 强度已切换为中档（空闲 ~D 秒 / 间隔 ~D 秒 / 每小时 ~A / 每天 ~A）~%~%"
                    (ui-tag-ok "强度") *self-iteration-idle-seconds*
                    *self-iteration-interval-seconds* (self-iteration-limit-label *self-iteration-hourly-limit*)
                    (self-iteration-limit-label *self-iteration-daily-limit*)))
           ((member arg '("high" "h" "高" "3") :test #'string=)
            (self-iteration-apply-intensity :high)
            (format t "  ~A 强度已切换为高档（空闲 ~D 秒 / 间隔 ~D 秒 / 每小时 ~A / 每天 ~A）~%~%"
                    (ui-tag-ok "强度") *self-iteration-idle-seconds*
                    *self-iteration-interval-seconds* (self-iteration-limit-label *self-iteration-hourly-limit*)
                    (self-iteration-limit-label *self-iteration-daily-limit*)))
           (t (format t "  用法：/self intensity [low|medium|high]~%~%"))))
       (finish-output)
       :handled)

      (t
       (format t "  用法：/self [status|intensity low|medium|high|toggle|on|off|run|log|backlog|shadow on|off]~%~%")
       (finish-output)
       :handled))))

;;; ── 工具注册：让主 Agent 也能查看/触发自省 ───────────

(when (fboundp 'register-tool)
  (register-tool
   "self_iteration"
   "自监管迭代子 Agent 的控制与查看工具。action=status 查看自省状态与最近发现；action=toggle 切换自省开关；action=run 立即执行一次空闲自省分析（会调用一次轻量 LLM，约数秒）；action=log 查看最近的自省日志；action=backlog 查看自省产生的待办建议。"
   (jobj "action" (prop-spec "string" "操作类型：status / toggle / run / log / backlog"
                             :enum '("status" "toggle" "run" "log" "backlog")))
   nil
   (lambda (args)
     (let ((action (string-downcase
                    (or (jget args "action") "status"))))
       (cond
         ((string= action "run")
          (let ((res (run-self-iteration-once :reason "工具调用")))
            (jobj "success" (if (getf res :ok) t :false)
                  "finding" (or (getf res :finding) "")
                  "suggestion" (or (getf res :suggestion) "")
                  "category" (or (getf res :category) "")
                  "priority" (or (getf res :priority) "")
                  "message" (getf res :message)
                  "logPath" *self-iteration-log-relative-path*)))
         ((string= action "log")
          (jobj "success" t
                "path" *self-iteration-log-relative-path*
                "lines" (self-iteration-tail-lines
                         (self-iteration-project-path *self-iteration-log-relative-path*) 30)))
         ((string= action "backlog")
          (jobj "success" t
                "path" *self-iteration-backlog-relative-path*
                "lines" (self-iteration-tail-lines
                         (self-iteration-project-path *self-iteration-backlog-relative-path*) 30)))
         ((string= action "toggle")
          (if *self-iteration-enabled*
              (setf *self-iteration-enabled* nil)
              (progn (setf *self-iteration-enabled* t
                           *self-iteration-failures* 0)
                     (ignore-errors (self-iteration-start-thread))))
          (jobj "success" t
                "enabled" (if *self-iteration-enabled* t :false)
                "message" (if *self-iteration-enabled*
                              "自省子 Agent 已开启"
                              "自省子 Agent 已暂停")))
         (t
          (jobj "success" t
                "enabled" (if *self-iteration-enabled* t :false)
                "threadAlive" (if (self-iteration-thread-alive-p) t :false)
                "cycles" *self-iteration-cycles*
                "consecutiveFailures" *self-iteration-failures*
                "idleSeconds" (self-iteration-idle-seconds-now)
                "lastFinding" (or *self-iteration-last-finding* "")
                "status" (self-iteration-status-lines))))))))

;;; ── 加载即启动后台线程（幂等） ───────────────────────

(ignore-errors (self-iteration-start-thread))

;;; ── 日志去重（归一化发现文本，避免同一结论反复刷屏） ─────────

(defun self-iteration-normalize-finding (text)
  "把发现文本归一化（去掉空白与常见标点）后取前 60 字符，作为「同一条结论」的签名。"
  (when (and text (stringp text) (plusp (length text)))
    (let ((out (make-string-output-stream))
          (skip " 	
，。、：；！？「」“”‘’()（）.,:;!?\"'"))
      (loop for ch across text
            unless (find ch skip)
              do (write-char ch out))
      (let ((s (get-output-stream-string out)))
        (subseq s 0 (min 60 (length s)))))))

(defun self-iteration-append-log (entry)
  "写入一条自省记录；最近 12KB 内出现过同一条发现（归一化后相同）时直接跳过，避免重复刷屏。"
  (let* ((path (self-iteration-project-path *self-iteration-log-relative-path*))
         (old (or (self-iteration-read-text path) ""))
         (tail (if (> (length old) 12000) (subseq old (- (length old) 12000)) old))
         (pos (search "- 发现:" entry))
         (start (and pos (+ pos (length "- 发现:"))))
         (end (and start (or (position #\Newline entry :start start) (length entry))))
         (find-text (and start (string-trim '(#\Space #\Tab) (subseq entry start end))))
         (sig (self-iteration-normalize-finding find-text)))
    (when (and path
               (not (and sig (search sig (self-iteration-normalize-finding tail)))))
      (self-iteration-append-text-file path entry
                                       *self-iteration-log-max-chars* 30000))))

