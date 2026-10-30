;;;; lisp/cli.lisp
;;;; 控制台交互式 CLI 对话界面（含 /model DeepSeek 配置器 + 原生 Lisp S-表达式直通热求值）

(in-package :cl-user)

(defvar *session-history* nil
  "当前 CLI 会话的消息历史（使用 defvar 以在热重载时保留对话上下文）。")

(defvar *session-total-tokens* 0
  "当前 CLI 会话累计消耗的总 token 数。")

(defun print-cli-banner (config)
  (let ((rule (ui-rule 62)))
    (format t "~%~A~%" rule)
    (format t "   ~A   ~A~%"
            (ui-colorize "1;36" "MyAgent")
            (ui-dim (format nil "Common Lisp · SBCL ~A" (lisp-implementation-version))))
    (format t "   ~A~%" (ui-dim "实时热重载 · 自我迭代 · 免重启"))
    (format t "~A~%" rule)
    (format t "   ~A 已加载工具 ~D 个~%"
            (ui-tag-info "工具") (length *tool-names-order*))
    (format t "       ~A~%" (ui-dim (format nil "~{~A~^, ~}" *tool-names-order*)))
    (format t "   ~A ~A~%"
            (ui-tag-key "指令")
            (ui-dim "/model · /tools · /md · /color · /emoji · /compact · /reload · /clear · /exit · 执行中 ESC 中断"))
    (format t "   ~A ~A~%"
            (ui-tag-info "Lisp")
            (ui-dim "输入 ,(1+ 2) 直接求值 Common Lisp"))
    (format t "~A~%" rule)
    (when (zerop (length (llm-config-api-key config)))
      (format t "   ~A 尚未配置 DeepSeek API Key，请先输入 /model 填入 Key。~%"
              (ui-tag-warn "提示")))
    (terpri)
    (finish-output)))

(defun print-cli-help ()
  (format t "~%  ~A 可用命令~%" (ui-tag-info "帮助"))
  (dolist (row '(("/model" "配置 DeepSeek API Key（交互式输入）")
                 ("/model <sk-xxx>" "快捷设置 API Key")
                 ("/tools" "查看当前已注册的全部工具")
                 ("/compact" "手动压缩历史：头尾保留，中段折叠为摘要")
                  ("/reload" "热重载全部 lisp/*.lisp 核心模块")
                 ("/md [on|off]" "开关 Markdown 渲染")
                 ("/color [on|off|auto]" "开关 ANSI 颜色")
                 ("/emoji [on|off]" "开关 emoji 转换（默认已转为文本标签）")
                 ("/eval <expr> 或 ,<expr>" "直接求值 Common Lisp 表达式")
                 ("/clear" "清空当前会话")
                 ("ESC" "执行中按 ESC 中断当前任务（已产生的上下文保留）")
                 ("/help" "显示本帮助")
                 ("/exit 或 /quit" "退出程序")))
    (format t "    ~A ~A~%"
            (ui-cyan (if (fboundp 'md-pad-to) (md-pad-to (first row) 40) (first row)))
            (ui-dim (second row))))
  (terpri)
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
         (format t "~%[配置] DeepSeek API Key (~A)~%" (get-myagent-config-path))
         (format t "  请输入 DeepSeek API Key (直接回车保持当前 Key): ")
         (finish-output)
         (let* ((key-in (cli-read-line ""
                               :prefix "  请输入 DeepSeek API Key (直接回车保持当前 Key): "
                               :prefix-printed t
))
                (new-key (trim-whitespace key-in)))
           (save-deepseek-config
            :api-key (if (> (length new-key) 0) new-key (llm-config-api-key current))
            :model *deepseek-default-model*
            :base-url *deepseek-default-base-url*)
           (format t "~%  ~A DeepSeek 配置已保存并立即生效。~%~%" (ui-tag-ok "成功"))
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
               (format t "~%  ~A DeepSeek API Key 已更新并保存。~%~%" (ui-tag-ok "成功")))
             (format t "~%  ~A 参数不是有效的 API Key。用法：/model <sk-xxx>，或直接输入 /model 进入交互配置。~%~%" (ui-tag-warn "警告")))
         (finish-output)))

      ;; 3. 多余参数：提示用法（不再支持切换模型）
      (t
       (format t "~%  ~A /model 现在只用于配置 API Key。用法：/model 或 /model <sk-xxx>~%~%" (ui-tag-warn "警告"))
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

;;;; ---- 终端输入层：裸控制台行编辑器（Windows）+ read-line 回退 ------------
;;;;
;;;; 这一版为什么推倒重来：
;;;;   前两版都是「让 conhost 按行缓冲回显，再用 ANSI 把回显擦掉」。实测发现：
;;;;     1. 擦除会和 conhost 的行编辑状态打架：光标被程序搬走后，conhost 仍按
;;;;        自己的行列记账，下一次回显 / 重绘会把刚擦掉的内容画回来 ——
;;;;        用户看到的就是「粘贴的几行擦不掉、删不掉」；
;;;;     2. 这台机器的控制台是 30 行、缓冲区高度也是 30 行（没有回滚缓冲），
;;;;        粘贴 3 行长中文（每行折成 2 行）必然滚屏，任何「按行数回退」的
;;;;        估算都会算错，残留是必然的。
;;;;
;;;; 所以这一版改为：程序自己接管回显。
;;;;   - 关掉 ENABLE_LINE_INPUT / ENABLE_ECHO_INPUT，用 ReadConsoleInputW 直接
;;;;     读按键记录，自己回显、自己处理退格 / 清行；
;;;;   - 粘贴进来的字符**根本不回显**，攒齐后只在提示符后打一行
;;;;     [粘贴 N 行 · M 字符]，按回车提交 —— 屏幕上没有任何需要擦除的东西；
;;;;   - 保留 ENABLE_PROCESSED_INPUT（Ctrl+C 行为不变）和 QuickEdit（右键菜单
;;;;     仍可复制）；Ctrl+V / Shift+Insert 由程序自己读剪贴板，右键粘贴由
;;;;     conhost 直接插入字符 —— 两条路径都能识别成粘贴；
;;;;   - stdin 不是控制台（管道 / 重定向 / --prompt 模式）时完全退回 read-line，
;;;;     只把连续多行合并成一条输入，不做任何屏幕操作。

;;; ── 参数 ─────────────────────────────────────────────

(defparameter *bracketed-paste* nil
  "是否启用终端 bracketed paste（DECSET 2004）。默认关闭：
conhost 只回开始标记、不回结束标记时，按标记收集会无限读取（表现为回车卡死）。
粘贴改由按键突发检测 + 剪贴板读取识别，不再依赖终端标记。")

(defparameter *cli-collapse-paste* t
  "是否把粘贴内容折叠成一行占位符。设 nil 则粘贴内容照常回显（等价粘贴即输入）。")

(defparameter *cli-raw-mode* :auto
  "是否在 Windows 真控制台上接管回显（裸输入模式）。
:auto / t 启用；nil 强制退回 read-line 方案。")

(defparameter *paste-burst-chars* 40
  "一批输入里字符按键达到这个数量就判定为粘贴。
阈值放大是为了不误伤中文输入法：一次上屏 2~10 个字很常见，不能当粘贴折叠。")

(defparameter *paste-idle-ms* 120
  "粘贴模式下，两次输入间隔小于该毫秒数就认为仍属于同一次粘贴；
超过则视为用户开始补写文字。")

(defparameter *paste-split-window-ms* 40
  "判定「孤立换行」是否属于粘贴内容的窗口（毫秒）。
终端把大段粘贴分批交付时，批次之间只隔几毫秒；而人手按回车至少 150ms 以上，
所以 40ms 既能把被批次边界切开的换行并回粘贴，又不会吞掉用户的提交回车。")

(defparameter *paste-continue-limit* 5000
  "回退方案里单次最多合并多少行，防止异常终端导致无限读取。")

(defparameter *paste-grace-polls* 3
  "回退方案里队列暂时空之后再轮询几次（每次 10ms），给终端分批灌入留补发时间。")

(defvar *cli-paste-active* nil
  "是否已向终端同步过 bracketed paste 状态（避免每轮重复发送 DECSET）。")

(defvar *raw-console-active* nil
  "是否已进入裸输入模式（关闭了行缓冲与回显）。")

(defvar *raw-console-saved-mode* nil
  "进入裸模式前的控制台模式，用于退出 / 降级时恢复。")

(defvar *cli-raw-supported* :unknown
  "裸输入模式可用性缓存：:unknown / t / nil。")

(defparameter *pb-start* (format nil "~C[200~~" (code-char 27)))
(defparameter *pb-end* (format nil "~C[201~~" (code-char 27)))

;;; 控制台模式位（用 defparameter，便于热重载）
(defparameter *con-processed-input* #x0001)
(defparameter *con-line-input* #x0002)
(defparameter *con-echo-input* #x0004)
(defparameter *con-window-input* #x0008)
(defparameter *con-mouse-input* #x0010)

;;; 虚拟键码 / 控制键状态
(defparameter *vk-back* 8)
(defparameter *vk-tab* 9)
(defparameter *vk-return* 13)
(defparameter *vk-escape* 27)
(defparameter *vk-insert* 45)
(defparameter *vk-v* 86)
(defparameter *vk-ctrl-u* 21)
(defparameter *ctrl-right* #x0004)
(defparameter *ctrl-left* #x0008)
(defparameter *ctrl-shift* #x0010)

;;; ── 基础工具 ─────────────────────────────────────────

(defun cli-console-p ()
  "当前输出是否接在真实交互式控制台上（重定向/管道时为 nil）。"
  #+win32
  (multiple-value-bind (h mode) (win32-console-handle-and-mode)
    (declare (ignore mode))
    (and h t))
  #-win32
  (and (uiop:getenv "TERM") t))

(defun cli-paste-enable ()
  "把终端的 bracketed paste 同步到 *bracketed-paste* 指定的状态（幂等）。
默认 nil，也就是主动发 DECSET 2004l，清掉上次异常退出可能留下的标记状态。"
  (when (and (cli-console-p) (not *cli-paste-active*))
    ;; 没有 ANSI 能力时不能发这串序列，否则屏幕上会多出一行转义垃圾
    (when (ignore-errors (ui-enable-vt))
      (ignore-errors
        (format t "~C[?2004~Ah" (code-char 27) (if *bracketed-paste* #\h #\l))
        (finish-output)))
    (setf *cli-paste-active* t))
  t)

(defun cli-paste-disable ()
  "关闭 bracketed paste，避免退出后 shell 里粘贴也带标记。"
  (when *cli-paste-active*
    (when (ignore-errors (ui-enable-vt))
      (ignore-errors
        (format t "~C[?2004l" (code-char 27))
        (finish-output)))
    (setf *cli-paste-active* nil))
  t)

(defun cli-raw-leave ()
  "恢复进入裸模式前的控制台模式（退出 / 降级时调用）。"
  (when (and *raw-console-active* *raw-console-saved-mode*)
    (ignore-errors (%console-set-input-mode *raw-console-saved-mode*))
    (setf *raw-console-active* nil))
  t)

(when (and (fboundp 'sb-ext:exit)
           (boundp 'sb-ext:*exit-hooks*))
  (unless (member 'cli-paste-disable sb-ext:*exit-hooks*)
    (ignore-errors (push 'cli-paste-disable sb-ext:*exit-hooks*)))
  (unless (member 'cli-raw-leave sb-ext:*exit-hooks*)
    (ignore-errors (push 'cli-raw-leave sb-ext:*exit-hooks*))))

(defun replace-all* (s old new)
  "把 s 中所有 old 替换为 new（不依赖正则）。"
  (if (or (null old) (zerop (length old)))
      s
      (with-output-to-string (o)
        (loop with start = 0
              for pos = (search old s :start2 start)
              do (write-string s o :start start :end (or pos (length s)))
              while pos
              do (write-string new o)
                 (setf start (+ pos (length old)))))))

(defun strip-paste-markers (line)
  "剥掉残留的 ESC[200~ / ESC[201~，返回 (values 文本 有开始标记 有结束标记)。"
  (let ((s line) (start nil) (end nil))
    (when (search *pb-start* s) (setf start t) (setf s (replace-all* s *pb-start* "")))
    (when (search *pb-end* s) (setf end t) (setf s (replace-all* s *pb-end* "")))
    (values (string-right-trim '(#\Return) s) start end)))

(defun split-lines* (s)
  "按换行切分（保留首尾空段）。"
  (loop with start = 0
        for pos = (position #\Newline s :start start)
        collect (subseq s start pos)
        while pos
        do (setf start (1+ pos))))

(defun paste-summary-label (text)
  "生成折叠后的占位符文字，例如 [粘贴 12 行 · 486 字符]。"
  (let* ((body (or text ""))
         (lines (split-lines* body))
         (n (length lines))
         (chars (length body))
         (first-real (find-if (lambda (l) (plusp (length (trim-whitespace l)))) lines))
         (preview (and first-real
                       (let ((w (trim-whitespace first-real)))
                         (if (> (length w) 18)
                             (concatenate 'string (subseq w 0 18) "…")
                             w)))))
    (if (> n 1)
        (format nil "[粘贴 ~D 行 · ~D 字符]" n chars)
        (format nil "[粘贴 ~D 字符~@[ · ~A~]]" chars preview))))

(defun strip-control-chars (s)
  "去掉 NUL 等不可打印控制字符（保留换行和 Tab）。"
  (with-output-to-string (o)
    (loop for ch across (or s "")
          do (let ((c (char-code ch)))
               (when (or (>= c 32) (= c 10) (= c 9))
                 (write-char ch o))))))

(defun normalize-newlines (s)
  "把 CRLF / CR / LF 统一成单个换行。"
  (with-output-to-string (o)
    (let ((prev-cr nil))
      (loop for ch across (or s "")
            do (cond ((char= ch #\Return)
                      (write-char #\Newline o)
                      (setf prev-cr t))
                     ((char= ch #\LineFeed)
                      (unless prev-cr (write-char #\Newline o))
                      (setf prev-cr nil))
                     (t (write-char ch o)
                        (setf prev-cr nil)))))))

;;; ── Win32 控制台 API ─────────────────────────────────

#+win32
(defvar *console-input-handle-cache* :unknown
  "stdin 的控制台句柄缓存；:unknown 未探测，nil 表示 stdin 不是控制台。")

#+win32
(defun %console-input-handle ()
  "标准输入的控制台句柄；stdin 被重定向 / 是管道时返回 nil。"
  (if (not (eq *console-input-handle-cache* :unknown))
      *console-input-handle-cache*
      (setf *console-input-handle-cache*
            (when (ensure-kernel32)
              (handler-case
                  (let* ((get-std-handle
                           (sb-alien:extern-alien "GetStdHandle"
                             (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
                         (get-console-mode
                           (sb-alien:extern-alien "GetConsoleMode"
                             (function sb-alien:int sb-sys:system-area-pointer
                                       (* sb-alien:unsigned-int))))
                         ;; STD_INPUT_HANDLE = (DWORD)-10 = #xFFFFFFF6
                         (h (sb-alien:alien-funcall get-std-handle #xFFFFFFF6))
                         (mode (sb-alien:make-alien sb-alien:unsigned-int)))
                    (unwind-protect
                         (and h
                              (not (sb-sys:sap= h (sb-sys:int-sap 0)))
                              (/= 0 (sb-alien:alien-funcall get-console-mode h mode))
                              h)
                      (sb-alien:free-alien mode)))
                (error () nil))))))

#-win32
(defun %console-input-handle () nil)

#+win32
(defun %console-get-input-mode ()
  "返回标准输入的控制台模式；stdin 不是控制台返回 nil。"
  (let ((h (%console-input-handle)))
    (when h
      (handler-case
          (let ((mode (sb-alien:make-alien sb-alien:unsigned-int)))
            (unwind-protect
                 (when (/= 0 (sb-alien:alien-funcall
                              (sb-alien:extern-alien "GetConsoleMode"
                                (function sb-alien:int sb-sys:system-area-pointer
                                          (* sb-alien:unsigned-int)))
                              h mode))
                   (sb-alien:deref mode))
              (sb-alien:free-alien mode)))
        (error () nil)))))

#-win32
(defun %console-get-input-mode () nil)

#+win32
(defun %console-set-input-mode (mode)
  "设置标准输入的控制台模式；成功返回 T。"
  (let ((h (%console-input-handle)))
    (and h
         (handler-case
             (/= 0 (sb-alien:alien-funcall
                    (sb-alien:extern-alien "SetConsoleMode"
                      (function sb-alien:int sb-sys:system-area-pointer
                                sb-alien:unsigned-int))
                    h mode))
           (error () nil)))))

#-win32
(defun %console-set-input-mode (mode) (declare (ignore mode)) nil)

#+win32
(defun %console-wait-input (ms)
  "等待控制台输入可用。返回 :signaled / :timeout / :error。"
  (let ((h (%console-input-handle)))
    (if (null h)
        :error
        (handler-case
            (case (sb-alien:alien-funcall
                   (sb-alien:extern-alien "WaitForSingleObject"
                     (function sb-alien:unsigned-int sb-sys:system-area-pointer
                               sb-alien:unsigned-int))
                   h ms)
              (#x00000000 :signaled)
              (#x00000102 :timeout)
              (t :error))
          (error () :error)))))

#-win32
(defun %console-wait-input (ms) (declare (ignore ms)) :error)

#+win32
(defun %console-peek-records (count)
  "偷看最多 count 条 INPUT_RECORD（不消费），返回 ((ETYPE KEYDOWN CHAR VK) ...)。
INPUT_RECORD 每条 20 字节：EventType@0、bKeyDown@4、wVirtualKeyCode@10、UnicodeChar@14。"
  (let ((h (%console-input-handle)))
    (when h
      (handler-case
          (let* ((peek (sb-alien:extern-alien "PeekConsoleInputW"
                         (function sb-alien:int sb-sys:system-area-pointer
                                   sb-sys:system-area-pointer sb-alien:unsigned-int
                                   (* sb-alien:unsigned-int))))
                 (buf (sb-alien:make-alien sb-alien:unsigned-char (* 20 count)))
                 (nread (sb-alien:make-alien sb-alien:unsigned-int)))
            (unwind-protect
                 (progn
                   (setf (sb-alien:deref nread) 0)
                   (if (= 0 (sb-alien:alien-funcall peek h (sb-alien:alien-sap buf) count nread))
                       nil
                       (let ((sap (sb-alien:alien-sap buf))
                             (n (min count (sb-alien:deref nread)))
                             (out nil))
                         (dotimes (i n)
                           (let ((base (* 20 i)))
                             (push (list (sb-sys:sap-ref-16 sap base)
                                         (sb-sys:sap-ref-32 sap (+ base 4))
                                         (sb-sys:sap-ref-16 sap (+ base 14))
                                         (sb-sys:sap-ref-16 sap (+ base 10)))
                                   out)))
                         (nreverse out))))
              (sb-alien:free-alien buf)
              (sb-alien:free-alien nread)))
        (error () nil)))))

#-win32
(defun %console-peek-records (count) (declare (ignore count)) nil)

#+win32
(defun %console-fetch-records (max)
  "阻塞读取最多 max 条输入记录（至少一条可用时才返回）。
每条记录返回 (ETYPE KEYDOWN REPEAT VK CHAR CTRL-STATE)。失败返回 nil。"
  (let ((h (%console-input-handle)))
    (when h
      (handler-case
          (let* ((read-input (sb-alien:extern-alien "ReadConsoleInputW"
                               (function sb-alien:int sb-sys:system-area-pointer
                                         sb-sys:system-area-pointer sb-alien:unsigned-int
                                         (* sb-alien:unsigned-int))))
                 (buf (sb-alien:make-alien sb-alien:unsigned-char (* 20 max)))
                 (nread (sb-alien:make-alien sb-alien:unsigned-int)))
            (unwind-protect
                 (progn
                   (setf (sb-alien:deref nread) 0)
                   (if (= 0 (sb-alien:alien-funcall read-input h (sb-alien:alien-sap buf)
                                                    max nread))
                       nil
                       (let ((sap (sb-alien:alien-sap buf))
                             (n (min max (sb-alien:deref nread)))
                             (out nil))
                         (dotimes (i n)
                           (let ((base (* 20 i)))
                             (push (list (sb-sys:sap-ref-16 sap base)          ; EventType
                                         (sb-sys:sap-ref-32 sap (+ base 4))    ; bKeyDown
                                         (sb-sys:sap-ref-16 sap (+ base 8))    ; wRepeatCount
                                         (sb-sys:sap-ref-16 sap (+ base 10))   ; wVirtualKeyCode
                                         (sb-sys:sap-ref-16 sap (+ base 14))   ; UnicodeChar
                                         (sb-sys:sap-ref-32 sap (+ base 16)))  ; dwControlKeyState
                                   out)))
                         (nreverse out))))
              (sb-alien:free-alien buf)
              (sb-alien:free-alien nread)))
        (error () nil)))))

#-win32
(defun %console-fetch-records (max) (declare (ignore max)) nil)

#+win32
(defun console-pending-char-p ()
  "队列里是否还有「会变成字符」的按键（跳过抬起 / 修饰键等记录）。
必须扫描多条记录：回车抬起事件经常排在队首，只看第一条会误判为没有输入。"
  (let ((recs (%console-peek-records 128)))
    (and recs
         (some (lambda (r)
                 (and (= (first r) 1) (/= (second r) 0) (/= (third r) 0)))
               recs))))

#-win32
(defun console-pending-char-p ()
  (ignore-errors (listen *standard-input*)))

;;; ── 剪贴板（Ctrl+V / Shift+Insert 用） ───────────────

#+win32
(defvar *user32-loaded* nil)

#+win32
(defun ensure-user32 ()
  (unless *user32-loaded*
    (handler-case
        (progn (sb-alien:load-shared-object "user32.dll")
               (setf *user32-loaded* t))
      (error () nil)))
  *user32-loaded*)

#+win32
(defun win32-clipboard-text ()
  "读取剪贴板 Unicode 文本；失败返回 nil。"
  (when (ensure-user32)
    (handler-case
        (let* ((nul (sb-sys:int-sap 0))
               (open (sb-alien:extern-alien "OpenClipboard"
                       (function sb-alien:int sb-sys:system-area-pointer)))
               (get-data (sb-alien:extern-alien "GetClipboardData"
                           (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
               (close (sb-alien:extern-alien "CloseClipboard" (function sb-alien:int)))
               (lock (sb-alien:extern-alien "GlobalLock"
                       (function sb-sys:system-area-pointer sb-sys:system-area-pointer)))
               (unlock (sb-alien:extern-alien "GlobalUnlock"
                           (function sb-alien:int sb-sys:system-area-pointer)))
               (opened nil))
          (dotimes (i 5)                 ; 剪贴板可能被别的进程占用，重试几次
            (declare (ignore i))
            (when (/= 0 (sb-alien:alien-funcall open nul))
              (setf opened t)
              (return))
            (sleep 0.02))
          (let ((result nil))
            (when opened
              (unwind-protect
                   (let ((handle (sb-alien:alien-funcall get-data 13)))  ; CF_UNICODETEXT
                     (when (and handle (not (sb-sys:sap= handle nul)))
                       (let ((ptr (sb-alien:alien-funcall lock handle)))
                         (when (and ptr (not (sb-sys:sap= ptr nul)))
                           (unwind-protect
                                (setf result (clipboard-ptr->string ptr))
                             (sb-alien:alien-funcall unlock handle))))))
                (sb-alien:alien-funcall close)))
            result))
      (error () nil))))

#+win32
(defun clipboard-ptr->string (ptr)
  "把剪贴板 Unicode 指针转成字符串（遇 NUL 结束）。"
  (let ((len 0))
    (loop for i from 0
          until (zerop (sb-sys:sap-ref-16 ptr (* 2 i)))
          do (incf len))
    (let ((s (make-string len)))
      (dotimes (i len)
        (setf (char s i) (code-char (sb-sys:sap-ref-16 ptr (* 2 i)))))
      s)))

#-win32
(defun win32-clipboard-text () nil)

;;; ── 裸输入模式的进入 / 判定 ──────────────────────────

(defun cli-raw-capable-p ()
  "是否可以在当前控制台上接管回显（Windows + 真控制台 + 支持 ANSI）。"
  (when (eq *cli-raw-supported* :unknown)
    (setf *cli-raw-supported*
          (and *cli-raw-mode*
               (%console-input-handle)
               (ignore-errors (ui-enable-vt))
               t)))
  (and *cli-raw-supported* t))

(defun cli-raw-enter ()
  "进入裸输入模式（只做一次，保持到进程退出）。成功返回 T。"
  (when (and (not *raw-console-active*) (%console-input-handle))
    (let ((mode (ignore-errors (%console-get-input-mode))))
      (when mode
        ;; 如果当前已经是裸模式（上次异常退出 / 热重载残留），
        ;; 保存的「原模式」必须按 cooked 还原，否则退出后终端没有回显。
        (let* ((raw-p (or (zerop (logand mode *con-line-input*))
                          (zerop (logand mode *con-echo-input*))))
               (saved (if raw-p
                          (logior mode *con-line-input* *con-echo-input*
                                  *con-mouse-input*)
                          mode))
               (new (logand mode
                            (lognot (logior *con-line-input* *con-echo-input*
                                            *con-window-input* *con-mouse-input*)))))
          (when (ignore-errors (%console-set-input-mode new))
            (setf *raw-console-saved-mode* saved
                  *raw-console-active* t))))))
  (and *raw-console-active* t))

;;; ── 行绘制 ──────────────────────────────────────────

(defun cli-input-prefix ()
  "主提示符（含颜色与结尾空格）。重绘时按原样输出，保证与首屏一致。"
  (format nil "~A " (ui-colorize "1;36" "You >")))

;;; ── 显示宽度与排版 ──────────────────────────────────

(defun cli-char-width (ch)
  "估算单字符显示宽度：CJK / 全角 / emoji 记 2，控制字符记 0，其余 1。"
  (let ((c (char-code ch)))
    (cond ((= c 9) 4)
          ((or (< c 32) (= c 127)) 0)
          ((or (and (>= c #x1100) (<= c #x115F))
               (and (>= c #x2E80) (<= c #xA4CF))
               (and (>= c #xAC00) (<= c #xD7A3))
               (and (>= c #xF900) (<= c #xFAFF))
               (and (>= c #xFE30) (<= c #xFE6F))
               (and (>= c #xFF00) (<= c #xFF60))
               (and (>= c #xFFE0) (<= c #xFFE6))
               (and (>= c #x1F300) (<= c #x1F64F))
               (and (>= c #x1F900) (<= c #x1F9FF))) 2)
          (t 1))))

(defun strip-ansi-escapes (s)
  "移除 ANSI CSI 转义序列（ESC [ 参数 终止字母），返回纯文本。
排版计算显示宽度前必须调用，否则颜色控制码会被当成可见字符。"
  (let* ((s (or s ""))
         (n (length s))
         (out (make-string-output-stream))
         (i 0)
         (esc (code-char 27)))
    (loop while (< i n)
          do (let ((ch (char s i)))
               (if (and (char= ch esc)
                        (< (1+ i) n)
                        (char= (char s (1+ i)) #\[))
                   ;; 跳过 ESC [ ... 终止字母（@ 到 ~ 之间的 7 位字节）
                   (let ((j (+ i 2)))
                     (loop while (and (< j n) (<= 48 (char-code (char s j)) 57))
                           do (incf j))
                     (loop while (and (< j n) (char= (char s j) #\;))
                           do (incf j)
                              (loop while (and (< j n)
                                               (<= 48 (char-code (char s j)) 57))
                                    do (incf j)))
                     (setf i (if (< j n) (1+ j) n)))
                   (progn (write-char ch out) (incf i)))))
    (get-output-stream-string out)))

(defun display-width* (s)
  "按终端实际显示宽度计数；自动忽略 ANSI 转义序列。"
  (loop for ch across (strip-ansi-escapes s) sum (cli-char-width ch)))

#+win32
(defun console-width ()
  "控制台可视区宽度（取 srWindow）；失败退回 COLUMNS 或 100。"
  (or (handler-case
          (when (ensure-kernel32)
            (let* ((get-std-handle
                     (sb-alien:extern-alien "GetStdHandle"
                       (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
                   (info-fn
                     (sb-alien:extern-alien "GetConsoleScreenBufferInfo"
                       (function sb-alien:int sb-sys:system-area-pointer
                                 sb-sys:system-area-pointer)))
                   (h (sb-alien:alien-funcall get-std-handle #xFFFFFFF5))
                   (buf (sb-alien:make-alien sb-alien:unsigned-char 32)))
              (unwind-protect
                   (when (and h (not (sb-sys:sap= h (sb-sys:int-sap 0)))
                              (/= 0 (sb-alien:alien-funcall info-fn h (sb-alien:alien-sap buf))))
                     (let* ((sap (sb-alien:alien-sap buf))
                            (left (sb-sys:sap-ref-16 sap 10))
                            (right (sb-sys:sap-ref-16 sap 14))
                            (w (1+ (- right left))))
                       (and (> w 10) w)))
                (sb-alien:free-alien buf))))
        (error () nil))
      (let ((c (ignore-errors (parse-integer (or (uiop:getenv "COLUMNS") "0")))))
        (and c (> c 10) c))
      100))

#-win32
(defun console-width ()
  (or (let ((c (ignore-errors (parse-integer (or (uiop:getenv "COLUMNS") "0")))))
        (and c (> c 10) c))
      100))

(defun cli-text-rows (text width &key (prefix-width 0) (cursor nil))
  "计算 text 在 width 列宽终端里的排布。
返回 (values 总行数 光标行 光标列 末尾行 末尾列)；行从 0 起，列为绝对列
（第 0 行叠加 prefix-width）。cursor 为 text 内的字符下标（nil 表示末尾）。"
  (let ((row 0) (col prefix-width)
        (crow 0) (ccol 0) (seen nil)
        (w (max 1 width)))
    (when (and cursor (zerop cursor))
      (setf crow row ccol col seen t))
    (loop for i from 0 below (length text)
          for ch = (char text i)
          do (cond
               ((char= ch #\Newline)
                (incf row)
                (setf col 0))
               (t (let ((cw (cli-char-width ch)))
                    (when (> (+ col cw) w)
                      (incf row)
                      (setf col 0))
                    (incf col cw))))
             (when (and cursor (= (1+ i) cursor))
               (setf crow row ccol col seen t)))
    (unless seen
      (setf crow row ccol col))
    (values (1+ row) crow ccol row col)))

(defvar *cli-input-start-y* nil
  "上一次绘制输入区时「起始行」的缓冲区绝对 Y 坐标。
 编辑模式下光标可能停在输入区中间某行，重绘时以该坐标为准计算上移量，
 避免用总行数上移冲过头（表现为每移动一次光标就多出一行）。")

(defun cli-render-input (drawn-rows prefix label text &key cursor hint (cursor-row nil))
  "把输入区重画为 prefix + label + text [+ hint]，光标定位到 text 内 cursor 处。
drawn-rows 是上一次绘制占用的行数（用于精确回退，避免滚屏后错位重绘）。
Windows 真控制台会用 GetConsoleScreenBufferInfo 实测占用行数，
避免提示换行 / 宽字符造成的估算偏差；其他情况退回布局模型。
返回 (values 本次占用行数 光标相对行)。"
  ;; 先把之前排队的输出真正刷到控制台，再测量光标位置
  (finish-output)
  (let* ((esc (code-char 27))
         (info (multiple-value-list (win32-console-screen-info)))
         (cy (first info))
         (fallback (max 0 (1- (or drawn-rows 1))))
         ;; 上一次绘制的起始行 → 当前光标行，这个差值就是必须回退的行数。
         ;; 光标在输入区中间（编辑模式移动光标）时也不会冲过头。
         (back (cond
                  ((and cursor-row (>= cursor-row 0)) cursor-row)
                  ((let ((d (and cy *cli-input-start-y*
                                 (- cy *cli-input-start-y*))))
                     (and d (>= d 0) (< d 2000)))
                   (- cy *cli-input-start-y*))
                  (t fallback))))
    (when (plusp back)
      (format t "~C[~DF" esc back))
    (format t "~C" #\Return)
    (format t "~C[J" esc)
    ;; 关键：上面的上移 / 清屏必须已经真正作用到控制台，才能读取光标行。
    ;; 否则 standard-output 还在缓冲区里，读到的是上一帧的光标位置，
    ;; start-y 记错会让下一次重绘上移不足（表现为移动光标时多出一行）。
    (finish-output)
    ;; 记录绘制起点行，后续用真实光标行差校正换行与滚屏
    (let ((start-y (nth-value 0 (win32-console-screen-info))))
      (setf *cli-input-start-y* start-y)
      (when prefix (format t "~A" prefix))
      (when label (format t "~A" (ui-dim label)))
      (format t "~A" (or text ""))
      (finish-output)
      (let ((width (console-width)))
        (multiple-value-bind (rows crow ccol endrow endcol)
            (cli-text-rows (or text "") width
                           :prefix-width (+ (display-width* prefix)
                                            (display-width* label))
                           :cursor cursor)
          (declare (ignore rows))
          (let ((last-row endrow))
            (when (and hint (plusp (length hint)))
              (let ((hintw (display-width* hint))
                    (hint-row endrow)
                    (hint-col endcol))
                (when (> (+ endcol hintw) width)
                  (terpri)
                  (setf hint-row (1+ endrow)
                        hint-col 0))
                (format t "~A" (ui-dim hint))
                (finish-output)
                (multiple-value-bind (hrows hcrow hccol hendrow hendcol)
                    (cli-text-rows hint width :prefix-width hint-col)
                  (declare (ignore hrows hcrow hccol hendcol))
                  (setf last-row (+ hint-row hendrow)))))
            (let* ((end-y (and start-y (nth-value 0 (win32-console-screen-info))))
                   (up (if (and start-y end-y)
                           (- end-y start-y crow)
                           (- last-row crow))))
              (when (plusp up)
                (format t "~C[~DA" esc up))
              (format t "~C[~DG" esc (1+ (max 0 (min ccol (1- width)))))
              (finish-output)
              (values (if (and start-y end-y)
                          (max 1 (1+ (- end-y start-y)))
                          (1+ last-row))
                      crow))))))))

;;; ── 编辑模式 / 提示文案 / 按键 ───────────────────────

(defparameter *vk-home* 36)
(defparameter *vk-end* 35)
(defparameter *vk-left* 37)
(defparameter *vk-up* 38)
(defparameter *vk-right* 39)
(defparameter *vk-down* 40)
(defparameter *vk-delete* 46)
(defparameter *vk-e* 69)

(defparameter *paste-double-back-ms* 600
  "粘贴模式下连按两次退格的判定窗口（毫秒），用于「两下删除整体」。")

(defparameter *edit-hint* "  (Esc 清除 · Ctrl+E 编辑 · Ctrl+Enter 发送)")
(defparameter *edit-hint-edit* "  (Esc 退出编辑 · Ctrl+Enter 发送)")
(defparameter *paste-delete-hint* "  (再按一次退格删除整段粘贴)")

;;; ── 裸模式行编辑器 ──────────────────────────────────

(defun batch-text (recs)
  "把一批按键记录里的字符拼成字符串（CR/LF 归一成单个换行，忽略控制字符）。"
  (with-output-to-string (o)
    (let ((prev-cr nil))
      (dolist (rec recs)
        (when (and (= (first rec) 1) (/= (second rec) 0) (plusp (fifth rec)))
          (let ((ch (code-char (fifth rec))))
            (cond
              ((char= ch #\Return)
               (write-char #\Newline o)
               (setf prev-cr t))
              ((char= ch #\LineFeed)
               (unless prev-cr (write-char #\Newline o))
               (setf prev-cr nil))
              ((> (char-code ch) 31)
               (write-char ch o)
               (setf prev-cr nil)))))))))

(defun read-console-line (&key (prefix nil) (prefix-printed nil) (start-y nil))
  "裸模式下读一行，返回字符串（不含结尾换行）；控制台失效返回 :eof。
prefix 是该行开头的静态文字（用于重绘）；prefix-printed 表示调用方已打印过。

按键：
  普通输入 : 字符回显；回车 = 发送；Ctrl+Enter = 直接发送
  粘贴     : 不回显，只显示 [粘贴 N 行 · M 字符]；回车 = 发送
             退格 = 先删掉粘贴块之后手动输入的字；光标回到粘贴块结尾后
                    600ms 内连按两次退格 = 整段粘贴一起删除
  多行编辑 : 方向键 / Home / End 移动；退格、Delete 任意删除
             Enter = 插入换行；Esc = 退出编辑；Ctrl+Enter = 直接发送"
  (declare (ignore start-y))
  (setf *cli-input-start-y* nil)
  (unless prefix-printed
    (when prefix (format t "~A" prefix) (finish-output)))
  (let* ((typed (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
         (paste nil)
         (paste-parts 0)
         (pasted (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
         (edit-mode nil)
         (edit-buf "")
         (edit-cursor 0)
         (drawn-rows 1)
          (drawn-cursor-row 0)
         (last-back-time 0)
         (last-time (get-internal-real-time))
         (done nil)
         (result nil))
    (labels
        ((ms-since (t0)
           (* 1000.0 (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
         (elapsed-ms ()
           (ms-since last-time))
         (paste-text ()
           (string-right-trim (list #\Newline #\Return) (or paste "")))
         (paste-label ()
           (let ((base (paste-summary-label (paste-text))))
             (if (> paste-parts 1)
                 (format nil "~A · ~D 段" base paste-parts)
                 base)))
         (paste-body ()
           (let ((p (paste-text))
                 (a (coerce pasted 'string)))
             (cond ((zerop (length p)) a)
                   ((zerop (length a)) p)
                   (t (format nil "~A~%~A" p a)))))
         (current-text ()
           (cond (edit-mode edit-buf)
                 (paste (coerce pasted 'string))
                 (t (coerce typed 'string))))
         (current-label ()
           (cond (edit-mode nil)
                 (paste (paste-label))
                 (t nil)))
         (current-hint ()
           (cond (edit-mode *edit-hint-edit*)
                 ((and paste
                       (plusp last-back-time)
                       (< (ms-since last-back-time) *paste-double-back-ms*))
                  *paste-delete-hint*)
                 (paste *edit-hint*)
                 (t nil)))
         (render ()
            (multiple-value-bind (rows crow)
                (cli-render-input drawn-rows prefix (current-label) (current-text)
                                  :cursor (and edit-mode edit-cursor)
                                  :hint (current-hint)
                                  :cursor-row drawn-cursor-row)
              (setf drawn-rows rows
                    drawn-cursor-row crow)))
         (echo-char (ch)
            (write-char ch)
            (finish-output)
            (multiple-value-bind (rows crow ccol endrow endcol)
                (cli-text-rows (current-text) (console-width)
                               :prefix-width (display-width* (or prefix "")))
              (declare (ignore crow ccol endcol))
              (setf drawn-rows rows
                    drawn-cursor-row endrow)))
         (submit ()
           (let ((body (cond (edit-mode edit-buf)
                             (paste (paste-body))
                             (t (coerce typed 'string)))))
             (format t "~%")
             (finish-output)
             (setf result body
                   done t)))
         (reset-all ()
           (setf (fill-pointer typed) 0
                 (fill-pointer pasted) 0
                 paste nil
                 paste-parts 0
                 edit-buf ""
                 edit-cursor 0
                 edit-mode nil
                 last-back-time 0))
         (add-paste (text &key (new-segment t))
           (when (and text (plusp (length text)))
             (when new-segment (incf paste-parts))
             (setf paste (concatenate 'string (or paste "") text)
                   last-back-time 0)
             (render)))
         (line-start (i)
           (1+ (or (position #\Newline edit-buf :end i :from-end t) -1)))
         (line-end-of (i)
           (or (position #\Newline edit-buf :start i) (length edit-buf)))
         (buf-insert (s)
           (when (plusp (length s))
             (setf edit-buf (concatenate 'string
                                         (subseq edit-buf 0 edit-cursor) s
                                         (subseq edit-buf edit-cursor))
                   edit-cursor (+ edit-cursor (length s)))
             (render)))
         (buf-back ()
           (when (plusp edit-cursor)
             (setf edit-buf (concatenate 'string
                                         (subseq edit-buf 0 (1- edit-cursor))
                                         (subseq edit-buf edit-cursor))
                   edit-cursor (1- edit-cursor))
             (render)))
         (buf-delete ()
           (when (< edit-cursor (length edit-buf))
             (setf edit-buf (concatenate 'string
                                         (subseq edit-buf 0 edit-cursor)
                                         (subseq edit-buf (1+ edit-cursor))))
             (render)))
         (buf-up ()
           (let* ((ls (line-start edit-cursor))
                  (col (- edit-cursor ls)))
             (if (zerop ls)
                 (setf edit-cursor 0)
                 (let* ((prev-end (1- ls))
                        (prev-start (1+ (or (position #\Newline edit-buf
                                                      :end prev-end :from-end t)
                                            -1))))
                   (setf edit-cursor (min (+ prev-start col) prev-end))))
             (render)))
         (buf-down ()
           (let* ((ls (line-start edit-cursor))
                  (le (line-end-of edit-cursor))
                  (col (- edit-cursor ls)))
             (if (>= le (length edit-buf))
                 (setf edit-cursor (length edit-buf))
                 (let* ((next-start (1+ le))
                        (next-end (or (position #\Newline edit-buf :start next-start)
                                      (length edit-buf))))
                   (setf edit-cursor (min (+ next-start col) next-end))))
             (render)))
         (start-edit ()
           (setf edit-buf (if paste (paste-body) (coerce typed 'string))
                 edit-cursor (length edit-buf)
                 edit-mode t
                 (fill-pointer typed) 0
                 (fill-pointer pasted) 0
                 paste nil
                 paste-parts 0
                 last-back-time 0)
           (render))
         (end-edit ()
           (setf edit-mode nil
                 paste (if (plusp (length edit-buf)) edit-buf nil)
                 paste-parts (if (plusp (length edit-buf)) 1 0)
                 (fill-pointer pasted) 0
                 last-back-time 0)
           (render))
         (paste-backspace ()
           (let ((now (get-internal-real-time)))
             (cond
               ;; 1) 先逐个删掉粘贴块之后手动输入的字：不动粘贴块，也不计入连按计时
               ((plusp (fill-pointer pasted))
                (decf (fill-pointer pasted))
                (setf last-back-time 0))
               ;; 2) 光标已在粘贴块结尾，600ms 内第二次退格 = 整段粘贴一起删除
               ((and (plusp last-back-time)
                     (< (ms-since last-back-time) *paste-double-back-ms*))
                (setf paste nil
                      paste-parts 0
                      (fill-pointer pasted) 0
                      last-back-time 0))
               ;; 3) 第一次退格只「待命」：保持多行压缩状态，光标停在粘贴块结尾
               (t
                (setf last-back-time now))))
           (render))
         (handle-backspace ()
           (cond (edit-mode (buf-back))
                 (paste (paste-backspace))
                 ((plusp (fill-pointer typed))
                  (decf (fill-pointer typed))
                  (render))))
         (handle-edit-key (vk ch)
           (cond
             ((= vk *vk-delete*) (buf-delete))
             ((= vk *vk-left*)
              (when (plusp edit-cursor) (decf edit-cursor) (render)))
             ((= vk *vk-right*)
              (when (< edit-cursor (length edit-buf)) (incf edit-cursor) (render)))
             ((= vk *vk-up*) (buf-up))
             ((= vk *vk-down*) (buf-down))
             ((= vk *vk-home*) (setf edit-cursor (line-start edit-cursor)) (render))
             ((= vk *vk-end*) (setf edit-cursor (line-end-of edit-cursor)) (render))
             (t (when (and (> ch 31) (/= vk *vk-tab*) (plusp ch))
                  (handle-char ch)))))
         (handle-clipboard ()
           (let ((clip (win32-clipboard-text)))
             (when clip
               (let ((clean (normalize-newlines (strip-control-chars clip))))
                 (if edit-mode
                     (buf-insert clean)
                     (add-paste clean))))))
         (handle-char (ch)
           (cond (edit-mode (buf-insert (string (code-char ch))))
                 (paste (vector-push-extend (code-char ch) pasted)
                        (setf last-back-time 0)
                        (render))
                 (t (vector-push-extend (code-char ch) typed)
                    (echo-char (code-char ch)))))
         (handle-record (rec)
           (let ((etype (first rec))
                 (down (second rec))
                 (vk (fourth rec))
                 (ch (fifth rec))
                 (ctrl (sixth rec)))
             (when (and (= etype 1) (/= down 0))
               (let ((ctrl-p (logtest ctrl (logior *ctrl-left* *ctrl-right*))))
                 (cond
                   ((and (or (= vk *vk-return*) (= ch 13) (= ch 10)) ctrl-p)
                    (submit))
                   ((or (= vk *vk-return*) (= ch 13) (= ch 10))
                    (if edit-mode
                        (buf-insert (string #\Newline))
                        (submit)))
                   ((= vk *vk-escape*)
                    (cond (edit-mode (end-edit))
                          (t (reset-all) (render))))
                   ((and (= vk *vk-e*) ctrl-p)
                    (unless edit-mode (start-edit)))
                   ((or (= vk *vk-back*) (= ch 8))
                    (handle-backspace))
                   (edit-mode
                    (handle-edit-key vk ch))
                   ((or (and (= vk *vk-v*) ctrl-p)
                        (and (= vk *vk-insert*) (logtest ctrl *ctrl-shift*)))
                    (handle-clipboard))
                   ((and (= ch *vk-ctrl-u*) ctrl-p)
                    (if edit-mode
                        (setf edit-buf "" edit-cursor 0)
                        (reset-all))
                    (render))
                   ((and (> ch 31) (/= vk *vk-tab*) (plusp ch))
                    (handle-char ch))))))))
      (loop until done
            do (let ((recs (ignore-errors (%console-fetch-records 32))))
                 (cond
                   ((null recs)
                    (if (null (%console-input-handle))
                        (setf result :eof done t)
                        (sleep 0.01)))
                   (t
                    (let* ((text (batch-text recs))
                           (nchars (length text))
                           (newline-p (and (find #\Newline text) t))
                           (continues (and paste (< (elapsed-ms) *paste-idle-ms*)))
                           (burst (and *cli-collapse-paste*
                                       (cond
                                         ((>= nchars *paste-burst-chars*) t)
                                         ((and newline-p (> nchars 1)) t)
                                         (newline-p (or (and paste (< (elapsed-ms) *paste-split-window-ms*))
                                                        (console-pending-char-p)))
                                          (t (and paste continues (> nchars 1)))))))
                      (setf last-time (get-internal-real-time))
                      (if burst
                          (if edit-mode
                              (buf-insert text)
                              (add-paste text :new-segment (not continues)))
                          (dolist (rec recs)
                            (unless done (handle-record rec))))))))))
      result))

;;; ── 回退方案：read-line + 连续多行合并 ──────────────

(defun collect-pasted-input (first-line &key (reader nil) (pending nil))
  "把同一批到达的连续多行合并成一条输入（stdin 被重定向 / 裸模式不可用时使用）。
返回 (values 文本 行数)。不等待回车、不做任何终端操作。"
  (let* ((rd (or reader (lambda () (read-line *standard-input* nil :eof))))
         (pend (or pending #'console-pending-char-p))
         (acc (list (string-right-trim '(#\Return) (or first-line ""))))
         (n 1))
    (labels ((pending-p ()
               (and (ignore-errors (funcall pend)) t))
             (wait-more-p ()
               "队列暂时空了，再轮询几轮给终端分批灌入留补发时间。"
               (dotimes (i *paste-grace-polls*)
                 (when (pending-p) (return-from wait-more-p t))
                 (sleep 0.01))
               nil))
      (loop
        (when (>= n *paste-continue-limit*) (return))
        (unless (or (pending-p) (wait-more-p)) (return))
        (let ((next (funcall rd)))
          (if (eq next :eof)
              (return)
              (progn
                (push (string-right-trim '(#\Return) next) acc)
                (incf n))))))
    (values (string-right-trim (list #\Newline #\Return)
                               (format nil "~{~A~^~%~}" (nreverse acc)))
            n)))

(defun cli-read-line (&optional (default :eof) &key (prefix nil) (prefix-printed t))
  "统一输入入口（供 /model 等需要单行输入的地方使用）。
Windows 真控制台走裸模式行编辑器；其余情况退回 read-line。"
  (if (and (cli-raw-capable-p) (cli-raw-enter))
      (let ((line (read-console-line :prefix prefix :prefix-printed prefix-printed)))
        (if (eq line :eof) default line))
      (read-line *standard-input* nil default)))

(defun cli-read-input-fallback ()
  "兼容输入：read-line + 连续多行合并。返回字符串或 :eof。"
  (let ((first-line (read-line *standard-input* nil :eof)))
    (when (eq first-line :eof)
      (return-from cli-read-input-fallback :eof))
    (collect-pasted-input first-line)))

(defun cli-sexp-continuation-p (line)
  "这一行是否需要按 S-表达式继续读后续行（,expr 或 /eval expr）。"
  (let ((trimmed (trim-whitespace (or line ""))))
    (or (and (>= (length trimmed) 1) (char= (char trimmed 0) #\,))
        (and (>= (length trimmed) 6) (string-equal "/eval " (subseq trimmed 0 6))))))

(defun cli-read-sexp-lines (first-line)
  "对 ,expr / /eval 支持多行续读：括号没闭合就继续读下一行。"
  (if (not (cli-sexp-continuation-p first-line))
      first-line
      (let ((acc first-line)
            (cont-prefix (format nil "~A " (ui-colorize "1;36" "... >"))))
        (loop until (sexp-complete-p acc)
              do (let ((next (if (and *raw-console-active* (cli-raw-capable-p))
                                 (read-console-line :prefix cont-prefix :prefix-printed nil)
                                 (progn (format t "~A" cont-prefix) (finish-output)
                                        (read-line *standard-input* nil :eof)))))
                   (when (eq next :eof) (return))
                   (setf acc (format nil "~A~%~A" acc next))))
        acc)))

(defun cli-prompt-repaint ()
  "读取输入前重绘底部状态栏。
主循环是常驻的已编译代码，热重载改不了其中已经执行到的语句；
而 read-cli-input 的调用是晚绑定的，重载即生效，所以把状态栏放在这里：
先擦掉外层刚打印的 `You >` 提示符，打印状态栏，再重印提示符。"
  (ignore-errors (cli-paste-enable))
  (when (and (fboundp 'ui-color-on-p) (ignore-errors (ui-color-on-p)))
    (let ((line (and (fboundp 'ctx-status-render)
                     (funcall 'ctx-status-render *session-history*))))
      ;; \r + ESC[2K：回到行首并整行擦除（清掉已打印的提示符）
      (format t "~C~C[2K" #\Return (code-char 27))
      (when line (format t "~A~%" line))
      (format t "~A" (cli-input-prefix))
      (finish-output))))

(defun read-cli-input ()
  "读取用户输入。
Windows 真控制台：程序自己接管回显，多行粘贴不回显，只在提示符后显示一行
[粘贴 N 行 · M 字符]，按回车提交。
其余情况（stdin 被重定向 / 终端不支持）：退回 read-line，只把连续多行合并成一条输入。"
  (cli-prompt-repaint)
  (cond
    ((and (cli-raw-capable-p) (cli-raw-enter))
     (let* ((start-y (ignore-errors (nth-value 0 (win32-console-screen-info))))
            (line (handler-case
                      (read-console-line :prefix (cli-input-prefix)
                                         :prefix-printed t
                                         :start-y start-y)
                    (error (e)
                      (format *error-output* "~%  ~A 终端输入层异常，已退回兼容模式: ~A~%"
                              (ui-tag-warn "警告") e)
                      (ignore-errors (cli-raw-leave))
                      (setf *cli-raw-supported* nil)
                      :fallback))))
       (cond
         ((eq line :fallback) (cli-read-input-fallback))
         ((eq line :eof) :eof)
         (t (cli-read-sexp-lines line)))))
    (t (cli-read-input-fallback))))


;;;; ---- 控制台清屏（多级回退，Windows / POSIX 通用）-------------------------
;;;;
;;;; 历史 Bug：Windows 上原先走 (uiop:run-program '("cmd" "/c" "cls")
;;;; :output *standard-output*) —— 子进程 stdout 被接成了「管道」，
;;;; cls 检测不到控制台句柄，于是什么都不做，屏幕上一条历史都没清掉。
;;;; 现在的策略（逐级降级）：
;;;;   1. 用 kernel32 的 GetConsoleMode 探测 stdout 是否真的是控制台；
;;;;   2. 若控制台已开启（或可开启）ENABLE_VIRTUAL_TERMINAL_PROCESSING，
;;;;      直接发 ANSI 序列 ESC[3J ESC[2J ESC[H（同时清回滚缓冲区）；
;;;;   3. 否则让 cmd 的 cls 继承真实控制台句柄（:output :interactive）；
;;;;   4. 最后兜底：刷空行把旧内容顶出可视区。

#+win32
(defvar *kernel32-loaded* nil
  "kernel32.dll 是否已成功加载（用于调用 Windows 控制台 API）。")

#+win32
(defun ensure-kernel32 ()
  (unless *kernel32-loaded*
    (handler-case
        (progn (sb-alien:load-shared-object "kernel32.dll")
               (setf *kernel32-loaded* t))
      (error () nil)))
  *kernel32-loaded*)

#+win32
(defun win32-console-handle-and-mode ()
  "探测当前标准输出是否为真实控制台。
是则返回 (values HANDLE MODE)，否则 (values nil nil)（例如输出被重定向到文件/管道）。"
  (when (ensure-kernel32)
    (handler-case
        (let* ((get-std-handle
                 (sb-alien:extern-alien "GetStdHandle"
                   (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
               (get-console-mode
                 (sb-alien:extern-alien "GetConsoleMode"
                   (function sb-alien:int sb-sys:system-area-pointer
                             (* sb-alien:unsigned-int))))
               ;; STD_OUTPUT_HANDLE = (DWORD)-11 = #xFFFFFFF5
               (h (sb-alien:alien-funcall get-std-handle #xFFFFFFF5))
               (mode (sb-alien:make-alien sb-alien:unsigned-int)))
          (unwind-protect
               (if (and h
                        (not (sb-sys:sap= h (sb-sys:int-sap 0)))
                        (/= 0 (sb-alien:alien-funcall get-console-mode h mode)))
                   (values h (sb-alien:deref mode))
                   (values nil nil))
            (sb-alien:free-alien mode)))
      (error () (values nil nil)))))

#+win32
(defun win32-console-screen-info ()
  "读取标准输出控制台的屏幕缓冲区信息。
返回 (values 光标绝对行 窗口顶行 光标列 窗口左列 窗口宽 窗口高)，
坐标原点为屏幕缓冲区左上角；输出不是真控制台或调用失败时返回 NIL。
调用方约定：第 1 个值 = 光标所在绝对行，第 2 个值 = 可视窗口顶行。"
  (when (ensure-kernel32)
    (handler-case
        (let* ((get-std-handle
                 (sb-alien:extern-alien "GetStdHandle"
                   (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
               (info-fn
                 (sb-alien:extern-alien "GetConsoleScreenBufferInfo"
                   (function sb-alien:int sb-sys:system-area-pointer
                             sb-sys:system-area-pointer)))
               ;; STD_OUTPUT_HANDLE = (DWORD)-11 = #xFFFFFFF5
               (h (sb-alien:alien-funcall get-std-handle #xFFFFFFF5))
               ;; CONSOLE_SCREEN_BUFFER_INFO 实际 22 字节，32 字节缓冲足够
               (buf (sb-alien:make-alien sb-alien:unsigned-char 32)))
          (unwind-protect
               (when (and h
                          (not (sb-sys:sap= h (sb-sys:int-sap 0)))
                          (/= 0 (sb-alien:alien-funcall info-fn h (sb-alien:alien-sap buf))))
                 ;; COORD dwCursorPosition: X=4 Y=6
                 ;; SMALL_RECT srWindow: Left=10 Top=12 Right=14 Bottom=16
                 (let* ((sap (sb-alien:alien-sap buf))
                        (cursor-x (sb-sys:sap-ref-16 sap 4))
                        (cursor-y (sb-sys:sap-ref-16 sap 6))
                        (win-left (sb-sys:sap-ref-16 sap 10))
                        (win-top (sb-sys:sap-ref-16 sap 12))
                        (win-right (sb-sys:sap-ref-16 sap 14))
                        (win-bottom (sb-sys:sap-ref-16 sap 16)))
                   (values cursor-y win-top cursor-x win-left
                           (1+ (- win-right win-left))
                           (1+ (- win-bottom win-top)))))
            (sb-alien:free-alien buf)))
      (error () nil))))

#-win32
(defun win32-console-screen-info ()
  "非 Windows 平台没有 Win32 控制台，返回 NIL。"
  nil)


#+win32
(defun win32-enable-vt-processing ()
  "尝试为当前 stdout 控制台开启 ENABLE_VIRTUAL_TERMINAL_PROCESSING（ANSI 支持）。成功返回 T。"
  (multiple-value-bind (h mode) (win32-console-handle-and-mode)
    (when h
      (if (logtest mode #x0004)
          t
          (handler-case
              (let ((set-console-mode
                      (sb-alien:extern-alien "SetConsoleMode"
                        (function sb-alien:int sb-sys:system-area-pointer
                                  sb-alien:unsigned-int))))
                (and (/= 0 (sb-alien:alien-funcall set-console-mode h (logior mode #x0004)))
                     t))
            (error () nil))))))

#-win32
(defun win32-enable-vt-processing () nil)

(defun emit-ansi-clear ()
  "发送 ANSI 清屏序列：清回滚缓冲区 + 清屏 + 光标归位。"
  (let ((esc (code-char 27)))
    (finish-output *standard-output*)
    (format *standard-output* "~C[3J~C[2J~C[H" esc esc esc)
    (finish-output *standard-output*)
    t))

(defun scroll-console-blank (&optional (lines 150))
  "最后手段：刷出一堆空行把旧内容顶出可视区（只在确认输出是控制台时使用）。"
  (finish-output *standard-output*)
  (dotimes (i lines)
    (declare (ignore i))
    (write-char #\Newline *standard-output*))
  (finish-output *standard-output*)
  t)

#+win32
(defun win32-cls-via-cmd ()
  "调用 cmd 的 cls 清屏。
关键点：必须用 :output :interactive 让子进程继承真实控制台句柄；
若重定向到 *standard-output*（管道/文件），cls 拿不到控制台，等于没执行。"
  (handler-case
      (progn
        (finish-output *standard-output*)
        (uiop:run-program '("cmd" "/c" "cls")
                          :input :interactive
                          :output :interactive
                          :error-output nil
                          :ignore-error-status t)
        (finish-output *standard-output*)
        t)
    (error () nil)))

#-win32
(defun win32-cls-via-cmd () nil)

(defun clear-console-screen ()
  "清空控制台屏幕（Windows 多级回退 / POSIX 走 ANSI）。返回 T 表示已尽力清屏。"
  (cond
    ;; ---------- Windows ----------
    ((uiop:os-windows-p)
     (multiple-value-bind (handle mode) (win32-console-handle-and-mode)
       (cond
         ;; 输出被重定向，没有屏幕可清，避免往管道里灌垃圾
         ((null handle) nil)
         ;; 1) 控制台原生支持 VT：直接发 ANSI
         ((logtest mode #x0004) (emit-ansi-clear))
         ;; 2) 尝试开启 VT 后再发 ANSI
         ((win32-enable-vt-processing) (emit-ansi-clear))
         ;; 3) 退回 cmd cls（继承真实控制台句柄）
         ((win32-cls-via-cmd))
         ;; 4) 兜底：刷空行
         (t (scroll-console-blank)))))
    ;; ---------- POSIX ----------
    (t
     (emit-ansi-clear))))

(defun handle-slash-command (input)
  "处理 CLI 斜杠指令或逗号 Lisp 求值指令。若已处理则返回 :handled，退出返回 :exit，否则返回 nil。"
  (let ((trimmed (trim-whitespace input)))
    (cond
      ((or (string-equal trimmed "/exit")
           (string-equal trimmed "/quit")
           (string-equal trimmed "exit")
           (string-equal trimmed "quit"))
       (progn (format t "~%  ~A 再见。~%" (ui-tag-info "退出")) (finish-output))
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
             (format t "  ~A Markdown 渲染已关闭（纯文本模式）。~%~%" (ui-tag-info "渲染")))
            ((string-equal arg "on")
             (setf *md-color-mode* t)
             (format t "  ~A Markdown 渲染已强制开启。~%~%" (ui-tag-info "渲染")))
            (t
             (format t "  ~A Markdown 渲染：~A（用法：/md on | /md off）~%~%" (ui-tag-info "渲染")
                     (cond ((eq *md-color-mode* t) "已强制开启")
                           ((null *md-color-mode*) "已关闭")
                           (t "自动检测")))))
          (finish-output)
          :handled))

      ((string-equal trimmed "/clear")
       (setf *session-history* nil
             *session-total-tokens* 0)
       (when (fboundp 'ctx-reset-session-stats)
         (funcall 'ctx-reset-session-stats))
       (clear-console-screen)
       (format t "  ~A~%" (ui-rule 52))
       (format t "   ~A 会话已清空 · 历史 0 条 · tokens 0~%" (ui-tag-ok "完成"))
       (format t "  ~A~%~%" (ui-rule 52))
       (finish-output)
       :handled)

       ((string-equal trimmed "/compact")
        (if (not (fboundp 'compact-history))
            (format t "  ~A 上下文模块未加载，无法压缩。~%~%" (ui-tag-err "失败"))
            (let ((before-chars (ctx-messages-chars *session-history*))
                  (before-n (length *session-history*)))
              (multiple-value-bind (new dropped saved) (compact-history *session-history*)
                (declare (ignore saved))
                (if (null new)
                    (format t "  ~A 历史 ~D 条 / ~,1FK 字符，没有可省略的中段（头部 ~D 条 + 尾部 ~D 条原样保留）。~%~%"
                            (ui-tag-info "压缩") before-n (/ before-chars 1000.0)
                            *ctx-head-messages* *ctx-tail-messages*)
                    (let ((after-chars (ctx-messages-chars new)))
                      (setf *session-history* new
                            *ctx-chars-after-compact* after-chars)
                      (format t "  ~A 省略 ~D 条中间消息 · ~,1FK -> ~,1FK 字符（约 ~,1FK -> ~,1FK tokens）· 前缀缓存重建一次~%~%"
                              (ui-tag-ok "压缩") dropped
                              (/ before-chars 1000.0) (/ after-chars 1000.0)
                              (/ before-chars 1000.0 *ctx-chars-per-token*)
                              (/ after-chars 1000.0 *ctx-chars-per-token*)))))))
        (finish-output)
        :handled)

      ((or (string-equal trimmed "/color")
           (and (> (length trimmed) 7)
                (string-equal "/color " (subseq trimmed 0 7))))
       (let ((arg (trim-whitespace (subseq trimmed 6))))
         (cond ((string-equal arg "off") (setf *ui-color-mode* nil))
               ((string-equal arg "on") (setf *ui-color-mode* t))
               (t (setf *ui-color-mode* :auto)))
         (ui-reset-color-cache)
         (format t "  ~A 颜色模式: ~A   样例: ~A~%~%"
                 (ui-tag-info "配色")
                 (cond ((eq *ui-color-mode* t) "强制开启")
                       ((null *ui-color-mode*) "关闭")
                       (t "自动检测"))
                 (ui-palette-preview))
         (finish-output)
         :handled))

      ((or (string-equal trimmed "/emoji")
           (and (> (length trimmed) 7)
                (string-equal "/emoji " (subseq trimmed 0 7))))
       (let ((arg (trim-whitespace (subseq trimmed 6))))
         (setf *md-emoji-mode* (not (string-equal arg "off")))
         (format t "  ~A emoji 转换: ~A（emoji 一律转成 [成功] / [警告] / [失败] 等彩色标签）~%~%"
                 (ui-tag-info "渲染")
                 (if *md-emoji-mode* "开启" "关闭"))
         (finish-output)
         :handled))

      ((string-equal trimmed "/tools")
       (format t "~%  ~A 当前已注册工具 ~D 个~%" (ui-tag-info "工具") (length *tool-names-order*))
       (dolist (name *tool-names-order*)
         (let ((t-entry (gethash name *tool-registry*)))
           (when t-entry
             (format t "    ~A ~A~%"
                     (ui-cyan (format nil "~26A" name))
                     (ui-dim (registered-tool-description t-entry))))))
       (terpri)
       (finish-output)
       :handled)

      ((string-equal trimmed "/reload")
       (dolist (f *core-lisp-files*)
         (hot-reload-lisp-file f))
       (format t "  ~A 全部核心模块已热重载完成。~%~%" (ui-tag-ok "成功"))
       (finish-output)
       :handled)

      ((or (string-equal trimmed "/rollback")
           (and (> (length trimmed) 10)
                (string-equal "/rollback " (subseq trimmed 0 10))))
       (let ((arg (if (> (length trimmed) 9) (trim-whitespace (subseq trimmed 9)) "")))
         (cond
           ((string-equal arg "baseline")
            (let ((restored (and (fboundp 'rollback-all-to-baseline)
                                 (funcall 'rollback-all-to-baseline))))
              (format t "  ~A 已将 ~D 个核心模块恢复到进程启动时的黄金快照。~%~%"
                      (ui-tag-ok "回滚") (length restored))))
           ((and (fboundp 'unverified-lisp-backups-p)
                 (funcall 'unverified-lisp-backups-p))
            (multiple-value-bind (rolled)
                (funcall 'rollback-unverified-lisp-files "用户手动执行 /rollback")
              (format t "  ~A 已回滚最近未验证的 ~D 个模块: ~{~A~^, ~}~%~%"
                      (ui-tag-ok "回滚") (length rolled) rolled)))
           (t
            (format t "  ~A 当前没有待回滚的未验证修改（如需恢复到启动时的初始版本，请输入 /rollback baseline）。~%~%"
                    (ui-tag-info "回滚")))))
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
             (format t "  => ~A~%~%" (jget res "result"))
             (format t "  ~A 求值错误: ~A~%~%" (ui-tag-err "失败") (jget res "error")))
         (finish-output)
         :handled))

      (t nil))))

(defun start-cli ()
  "启动控制台交互式对话主循环。"
  (let ((config (resolve-llm-config :allow-empty-key t)))
    (print-cli-banner config)
    (loop for input-count from 1
          do (format t "~A " (ui-colorize "1;36" "You >"))
      (finish-output)
      (let ((line (handler-case (read-cli-input)
                    (end-of-file () :eof)
                    (error (e)
                      (format *error-output* "~%读取输入错误: ~A~%" e)
                      ""))))
        (when (eq line :eof)
          (if (= input-count 1)
              (progn
                (format t "~%[!] 标准输入(stdin)在启动时就是 EOF / 已被关闭。~%   说明程序不是在交互式终端里启动的（可能被重定向、管道，或被 chcp 之类命令吞掉了 stdin）。~%   请在 cmd 或 PowerShell 窗口运行 start.bat，或使用单次模式：~%   sbcl --load run.lisp --prompt 你好~%")
                (finish-output)
                (return :eof-at-startup))
              (progn
                (format t "~%  收到 EOF，退出。~%")
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
                             (cancelled (getf result :cancelled))
                             (in-tok (or (getf result :input-tokens) 0))
                             (out-tok (or (getf result :output-tokens) 0)))
                        (setf *session-history* new-history)
                        (incf *session-total-tokens* (+ in-tok out-tok))
                        (if cancelled
                            (format t "~%~A ~A~%    （历史仍保留 ~D 条消息，可直接继续提问；输入 /clear 可清空）~%~%"
                                    (ui-tag-warn "中断")
                                    (if (fboundp 'render-markdown)
                                        (funcall 'render-markdown answer)
                                        answer)
                                    (length *session-history*))
                            (format t "~%~A~%~A~%~%" (ui-colorize "1;32" "Agent >")
                                    (if (fboundp 'render-markdown)
                                        (funcall 'render-markdown answer)
                                        answer)))
                        (finish-output))

                   (error (e)
                     (when (and (fboundp 'unverified-lisp-backups-p)
                                (funcall 'unverified-lisp-backups-p)
                                (fboundp 'rollback-unverified-lisp-files))
                       (ignore-errors (funcall 'rollback-unverified-lisp-files e)))
                     (format *error-output* "~%  ~A 执行异常: ~A~%~%" (ui-tag-err "失败") e)
                     (finish-output))))))))))))

;;; ── ESC 中断：Agent 执行期间的按键探测 ───────────────
;;; 说明：Agent 任务执行时主循环不在 read-console-line 里，但控制台仍处于
;;; 裸输入模式，因此可以直接从输入队列里非阻塞地 peek 出 ESC 按键。

(defun cli-escape-watchable-p ()
  "是否可以在 Agent 执行期间从控制台输入队列中检测 ESC 按键。"
  #+win32
  (and (%console-input-handle) t)
  #-win32
  nil)

(defun cli-escape-key-pending-p ()
  "非阻塞检查输入队列里是否有 ESC 按下（不消费记录）。
%console-peek-records 返回 (ETYPE bKeyDown UnicodeChar VK)，同时比对虚拟键码与字符码。"
  #+win32
  (let ((recs (ignore-errors (%console-peek-records 128))))
    (and recs
         (some (lambda (r)
                 (and (= (first r) 1)             ; KEY_EVENT
                      (/= (second r) 0)           ; 按下（不是抬起）
                      (or (and (fourth r) (= (fourth r) *vk-escape*))
                          (= (third r) *vk-escape*)))) ; ESC（虚拟键码或字符码）
               recs)))
  #-win32
  nil)

(defun cli-consume-escape-presses ()
  "消费掉输入队列中已到达的记录（含 ESC），避免中断标记残留影响下一次输入。"
  #+win32
  (let ((recs (ignore-errors (%console-peek-records 128))))
    (when recs
      (ignore-errors (%console-fetch-records (length recs))))
    t)
  #-win32
  nil)


;;; ── 用户消息回显（历史定位） ─────────────────────────

(defparameter *cli-user-echo-bg* "48;5;253"
  "用户消息回显的背景色（256 色 SGR 参数，浅灰）。设为 NIL 则不加背景。")

(defparameter *cli-user-echo-fg* "30"
  "用户消息回显的前景色；浅色背景上用深色文字，保证可读。")

(defun cli-user-echo-line (text first)
  "把一行用户消息渲染成整行浅色背景条。首行带 You 标签，续行用等宽缩进对齐。
彩色模式下右侧补空格铺满一行，形成连续的浅色区块；颜色关闭时输出纯文本。"
  (let* ((prefix (if first " You  " "      "))
         (color-on (and *cli-user-echo-bg* (ui-color-on-p)))
         (width (max 40 (console-width)))
         (dw (+ (display-width* prefix) (display-width* text)))
         (pad (if color-on (max 0 (- width 1 dw)) 0))
         (style (if *cli-user-echo-fg*
                    (format nil "~A;~A" *cli-user-echo-bg* *cli-user-echo-fg*)
                    *cli-user-echo-bg*)))
    (if color-on
        (format nil "~A[~Am~A~A~A~A[0m"
                *ui-esc* style prefix text
                (make-string pad :initial-element #\Space)
                *ui-esc*)
        (format nil "~A~A" prefix text))))

(defun cli-echo-user-message (text)
  "把刚提交的用户消息以浅色背景整行回显到历史里（粘贴内容也会展开），
便于滚动历史时一眼定位上一次提问。不做书签/竖条标记，只铺一层浅底。"
  (let ((lines (split-lines* (or text ""))))
    (format t "~%")
    (loop for l in lines
          for first = t then nil
          do (format t "~A~%" (cli-user-echo-line l first)))
    (format t "~%")
    (finish-output)))

