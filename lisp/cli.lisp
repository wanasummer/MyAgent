;;;; lisp/cli.lisp
;;;; 控制台交互式 CLI 对话界面（含 /model DeepSeek 配置器 + 原生 Lisp S-表达式直通热求值）

(in-package :cl-user)

(defvar *session-history* nil
  "当前 CLI 会话的消息历史（使用 defvar 以在热重载时保留对话上下文）。")

(defvar *session-total-tokens* 0
  "当前 CLI 会话累计消耗的总 token 数。")

(defparameter *banner-lain-grid*
  '("............................"
    ".......dddddddddddddd......."
    ".....ddHHHHHHHHHHHHHHdd....."
    "....dHHHhhhhmHHmhhhhHHHd...."
    "...dHHhhHHHHmHHmHHHHhhHHd..."
    "..dHHHHHHHHmHHHHmHHHHHHHHd.."
    "..dHHHHdHHmHHmHHmHHdHHHHHd.."
    ".dHHHHdSHHmSSmSHHmSHdHHHHHd."
    ".dHHHmSSHHSSSmSHHSSHHmHHHHd."
    "..dHHmSSmsSSSsSmsSSsmSHHHd.."
    "..dHHmSSSSSsSSsSsSSSSSHHHd.."
    "..dHHHdSeeesSSSSseeeSdHHHd.."
    "..dHHHmSSSSSSSSSSSSSSmHHHd.."
    "..dHHHmSEEEESSSSEEEESmXHHHXd"
    "..dHmHHSIIwISSSSIIwISHHXHXHd"
    "...dHmHSwiiISSSSwiiISHHHXHHd"
    "...dHmHSSSSSSSSSSSSSSmHXHXHd"
    "....dmHssSSSSSSSSSSssHXHHHXd"
    "....d.d.sssSSSSSSsssdmHHmHd."
    "........dddssssssddd.dHHmHd."
    "...........ddNssNdd...dHHd.."
    ".........ddNNNNNNNNdd.dHHd.."
    "........dNNNNNNNNNNNNddHmd.."
    ".......dNNNNNNNNNNNNNNd.d..."
    "......dNNNNNNNNNNNNNNNd.d..."
    "............................")
  "《玲音》(Iwakura Lain) 26x28 像素头像：参差碎刘海 + 分缕短发 + 半垂忧郁眼眸 + 醒目金黄 X 发卡与右侧垂肩单束长发。")

(defparameter *banner-lain-palette*
  '((#\. nil               #\Space)
    (#\d (38 16 18)        #\+)
    (#\m (74 32 30)        #\+)
    (#\H (114 54 46)       #\#)
    (#\h (156 82 68)       #\#)
    (#\S (242 228 226)     #\.)
    (#\s (210 190 190)     #\:)
    (#\e (86 44 44)        #\~)
    (#\E (34 16 20)        #\=)
    (#\I (24 12 16)        #\@)
    (#\i (108 46 48)       #\o)
    (#\w (255 255 255)     #\*)
    (#\X (250 214 60)      #\X)
    (#\N (36 42 62)        #\%))
  "Lain 像素调色板：四阶分缕栗棕发色 + 冷白瓷肌 + 参差碎刘海 + 半垂暗红眼眸 + 亮金 X 发卡 + 深色毛衣领。")

(defparameter *banner-whale-grid*
  '("............................"
    "............................"
    "............................"
    "............................"
    ".............ss....L........"
    ".....scccccLBBc...sBs......."
    "...cBBBBBBBBBB....sBBLs.sscB"
    "..LBBBBBBBBBBBBc...BBBBBBBBL"
    ".LBBBBBBBBBBBBBBc..LBBBBBBBs"
    "sBBBBBBBBBBBBBBBBc..LBBBBBc."
    "cBBBBBBBBBBBBBBBBBc..BBLcs.."
    "LB...scBBBBBBBBBBBBLcBBc...."
    "BB......cBBBBBLcsLBBBBBs...."
    "BB........LBBBLL..BBBBB....."
    "LBc........LBBBBs.cBBBL....."
    "cBB.........BBBBBLBBBBc....."
    "sBBs........sBBBBBBBBB......"
    ".BBB.........cBBBBBBBs......"
    ".sBBL....Lc...LBBBBBc......."
    "..cBBBc..cBBc..LBBBLs......."
    "...sBBBBLBBBBLs.cBBBBB......"
    ".....LBBBBBBBBBBLscccs......"
    "......scBBBBBBLs............"
    "..........ss................"
    "............................"
    "............................")
  "DeepSeek 官方蓝鲸图标 26x28 超采样抗锯齿像素画。")

(defparameter *banner-whale-palette*
  '((#\. nil               #\Space)
    (#\B (83 109 254)      #\#)
    (#\L (70 92 218)       #\#)
    (#\c (54 72 168)       #\+)
    (#\s (36 48 110)       #\.))
  "DeepSeek 鲸鱼像素调色板：(字符 (R G B) 无色回退字符)。")

(defun banner-pixel-rgb (ch palette)
  (second (assoc ch palette)))

(defun banner-pixel-fallback (ch palette)
  (or (third (assoc ch palette)) #\Space))

(defun banner-render-halfblock-pair (top-row bot-row palette)
  "使用 Unicode 半高块 (▀/▄/█) + 24-bit RGB 将上下两行像素合成为单行终端输出。
透明像素 (nil) 不设置背景色，完美适配任意深色/浅色终端背景。"
  (let ((w (min (length top-row) (length bot-row)))
        (color-on (ui-color-on-p))
        (esc *ui-esc*))
    (with-output-to-string (o)
      (dotimes (i w)
        (let* ((tc (char top-row i))
               (bc (char bot-row i))
               (trgb (banner-pixel-rgb tc palette))
               (brgb (banner-pixel-rgb bc palette)))
          (if (not color-on)
              (write-char (if trgb
                              (banner-pixel-fallback tc palette)
                              (banner-pixel-fallback bc palette))
                          o)
              (cond
                ;; 1. 上下均透明
                ((and (null trgb) (null brgb))
                 (write-char #\Space o))
                ;; 2. 上下同色 → 实心全块 █
                ((and trgb brgb (equal trgb brgb))
                 (format o "~A[38;2;~D;~D;~Dm~C~A[0m"
                         esc (first trgb) (second trgb) (third trgb)
                         (code-char #x2588) esc))
                ;; 3. 仅上半格有色，下半格透明 → 上半块 ▀（前景着色，背景透明）
                ((and trgb (null brgb))
                 (format o "~A[38;2;~D;~D;~Dm~C~A[0m"
                         esc (first trgb) (second trgb) (third trgb)
                         (code-char #x2580) esc))
                ;; 4. 仅下半格有色，上半格透明 → 下半块 ▄（前景着色，背景透明）
                ((and (null trgb) brgb)
                 (format o "~A[38;2;~D;~D;~Dm~C~A[0m"
                         esc (first brgb) (second brgb) (third brgb)
                         (code-char #x2584) esc))
                ;; 5. 上下均有色且不同 → 上半块 ▀（前景=上像素，背景=下像素）
                (t
                 (format o "~A[38;2;~D;~D;~D;48;2;~D;~D;~Dm~C~A[0m"
                         esc
                         (first trgb) (second trgb) (third trgb)
                         (first brgb) (second brgb) (third brgb)
                         (code-char #x2580) esc)))))))))

(defun print-cli-pixel-art ()
  "并排打印 Lain（经典黑白剪影肖像）与 DeepSeek（官方蓝鲸）的 26x28 半块高精度像素画。"
  (loop for (l1 l2) on *banner-lain-grid* by #'cddr
        for (w1 w2) on *banner-whale-grid* by #'cddr
        when (and l1 l2 w1 w2)
        do (format t "    ~A    ~A~%"
                   (banner-render-halfblock-pair l1 l2 *banner-lain-palette*)
                   (banner-render-halfblock-pair w1 w2 *banner-whale-palette*)))
  (format t "       ~A                ~A~%"
          (ui-colorize "1;37" "IWAKURA LAIN · 岩仓玲音")
          (ui-colorize "1;34" "DEEPSEEK · 深度求索")))

(defun print-cli-banner (config)
  (let ((rule (ui-rule 64)))
    (format t "~%~A~%" rule)
    (format t "   ~A   ~A~%"
            (ui-colorize "1;36" "MyAgent")
            (ui-dim (format nil "Common Lisp · SBCL ~A" (lisp-implementation-version))))
    (format t "   ~A~%" (ui-dim "灵感来自《玲音》(Serial Experiments Lain)"))
    (format t "   ~A~%" (ui-dim "由 DeepSeek 驱动的自我迭代 nano agent · 实时热重载 · 免重启"))
    (format t "~A~%" rule)
    (print-cli-pixel-art)
    (format t "~A~%" rule)
    (format t "   ~A 已加载工具 ~D 个~%"
            (ui-tag-info "工具") (length *tool-names-order*))
    (format t "       ~A~%" (ui-dim (format nil "~{~A~^, ~}" *tool-names-order*)))
    (format t "   ~A ~A~%"
            (ui-tag-key "指令")
            (ui-dim "/model · /tools · /md · /color · /emoji · /compact · /reload · /rollback · /clear · /exit · ESC 中断"))
    (format t "   ~A ~A~%"
            (ui-tag-info "Lisp")
            (ui-dim "输入 ,(1+ 2) 直接求值 Common Lisp"))
    (format t "~A~%" rule)
    (format t "   ~A 欢迎回来。说需求就行，我会直接改自己的代码并热重载。~%" (ui-tag-ok "欢迎"))
    (format t "   ~A~%" (ui-dim "Present day, present time."))
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
                 ("/self intensity low|medium|high" "设置自省强度（默认高档）；/self status 查看当前档位")
                 ("/compact" "手动压缩历史：头尾保留，中段折叠为摘要")
                 ("/reload" "热重载全部 lisp/*.lisp 核心模块")
                 ("/rollback [baseline]" "回滚最近未验证的热重载修改（加 baseline 恢复启动快照）")
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

(defparameter *paste-continuation-ms* 400
  "判定「这一批字符仍属于正在进行的那次粘贴」的时间窗口（毫秒）。
终端把一次粘贴拆成多批注入时，批与批之间可能有几十到几百毫秒的空隙；
超过该窗口且输入队列已经空，才视为用户开始手打。")

(defparameter *paste-absorb-ms* 60
  "允许把 typed 里的字符并入新粘贴块的判定窗口（毫秒）。
只有「终端把一次粘贴拆成多批、第一批先被当成普通输入落进 typed」这种毫秒级
衔接才吸收；人手打字后再粘贴（通常间隔 100ms 以上）必须保持成独立前缀，
否则两段文字会黏成同一行。")

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
(defun %console-wait-input (h timeout-ms)
  "等待控制台输入句柄变为可读：0=有输入，258=超时。"
  (let ((f (sb-alien:extern-alien "WaitForSingleObject"
             (function sb-alien:unsigned-int sb-sys:system-area-pointer
                       sb-alien:unsigned-int))))
    (sb-alien:alien-funcall f h timeout-ms)))

(defun %console-fetch-records (max &optional (timeout-ms 100))
  "最多等待 timeout-ms 毫秒读取输入记录；超时返回 :timeout，让调用方继续处理提示与状态灯。
每条记录返回 (ETYPE KEYDOWN REPEAT VK CHAR CTRL-STATE)。失败返回 nil。"
  (let ((h (%console-input-handle)))
    (when h
      (when (= 258 (%console-wait-input h timeout-ms))
        (return-from %console-fetch-records :timeout))
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
(defun %console-fetch-records (max &optional (timeout-ms 100)) (declare (ignore max timeout-ms)) nil)

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

#+win32
(defun win32-set-cursor-position (y x)
  "把光标直接定位到屏幕缓冲区的绝对坐标 (y x)；失败返回 nil。
绝对定位可以彻底避开折行 / 滚屏 / 窗口缩放后「相对上移量算错」的问题
（那种偏差的表现就是输入区不停新增重复行）。"
  (when (ensure-kernel32)
    (handler-case
        (let* ((get-std-handle
                 (sb-alien:extern-alien "GetStdHandle"
                   (function sb-sys:system-area-pointer sb-alien:unsigned-int)))
               (set-pos
                 (sb-alien:extern-alien "SetConsoleCursorPosition"
                   (function sb-alien:int sb-sys:system-area-pointer sb-alien:unsigned-int)))
               (h (sb-alien:alien-funcall get-std-handle #xFFFFFFF5))
               (coord (logior (logand (max 0 x) #xFFFF)
                              (ash (logand (max 0 y) #xFFFF) 16))))
          (and h
               (not (sb-sys:sap= h (sb-sys:int-sap 0)))
               (/= 0 (sb-alien:alien-funcall set-pos h coord))))
      (error () nil))))

#-win32
(defun win32-set-cursor-position (y x)
  (declare (ignore y x))
  nil)

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

(defparameter *render-trace* nil
  "最近 200 次输入区重绘的现场快照（:start 起始行 / :cy 当前光标行 / :back 回退行数 / :abs 绝对定位是否成功 / :rows 估算行数 / :crow 光标相对行），仅用于排查折行后重复新增行。")

;;; ── 自省状态灯（提示栏最右侧常驻） ──────────────────
(defvar *cli-status-row* nil
  "底部状态栏在屏幕上的缓冲区行号；用于在其右端原位刷新自省状态灯。")

(defvar *cli-status-line-text* nil
  "最近一次打印的完整状态栏文本（含右侧状态灯），供插入自省提示时原样重印。")

(defvar *cli-status-last* nil
  "状态栏右端最近一次绘制的状态灯文本，避免重复刷新。")

(defun cli-self-iteration-refresh-status ()
  "在输入为空时原位刷新状态栏右端的状态灯（只在状态变化时写一次，不动输入行）。"
  (when (and *cli-status-row* (fboundp 'self-iteration-indicator))
    (let ((text (ignore-errors (self-iteration-indicator))))
      (when (and (stringp text) (not (equal text *cli-status-last*)))
        (let* ((w (console-width))
               (iw (display-width* text))
               (col (- (1- w) iw)))
          (when (and (>= col 0)
                     (or (null *cli-input-start-y*)
                         (= *cli-status-row* (1- *cli-input-start-y*))))
            (multiple-value-bind (cy cx) (win32-console-screen-info)
              (when (and cy cx (win32-set-cursor-position *cli-status-row* col))
                (finish-output)
                (format t "~A" text)
                (finish-output)
                (win32-set-cursor-position cy cx)
                (finish-output)
                (setf *cli-status-last* text)))))))))


(defvar *cli-indicator-y* nil
  "状态灯所在行的缓冲区 Y 坐标；nil 表示当前未显示。")

(defvar *cli-indicator-col* nil
  "状态灯起始列（0 基）。")

(defvar *cli-indicator-last-tick* 0
  "上次状态灯动画刷新的时间（internal-real-time）。")
(defvar *cli-indicator-offset* 0
  "状态灯相对输入区首行的行偏移：1=吸附在上方状态栏那一行，0=画在输入行本身。")

(defvar *cli-indicator-used* 0
  "状态灯所在行已被占用的显示宽度，用于判断右侧是否还放得下。")

(defun cli-draw-indicator (&key text row col)
  "在 (ROW, COL) 绘制状态灯并恢复原光标；无控制台能力时静默跳过。"
  (when (and text row col)
    ;; 先把缓冲输出真正刷到控制台，再挪光标，避免文字写到错误位置
    (finish-output)
    (multiple-value-bind (cy cx) (win32-console-screen-info)
      (when (and cy cx (win32-set-cursor-position row col))
        (format t "~A" text)
        (finish-output)
        (win32-set-cursor-position cy cx)
        (finish-output)
        t))))

(defun cli-indicator-show (&key (used 0) row)
  "计算并绘制状态灯：首行剩余空间足够才显示，避免覆盖正文。"
  (let* ((text (and (fboundp 'self-iteration-indicator)
                    (ignore-errors (self-iteration-indicator))))
         (w (and text (display-width* text)))
         (width (console-width))
         (y (or row (nth-value 0 (win32-console-screen-info)))))
    (cond
      ((null text) (setf *cli-indicator-y* nil) nil)
      ((and w y (>= width (+ used w 2)))
       (setf *cli-indicator-y* y
             *cli-indicator-col* (- width w))
       (cli-draw-indicator :text text :row y :col (- width w)))
      (t (setf *cli-indicator-y* nil) nil))))

(defun cli-self-iteration-animate ()
  "等待按键时按需刷新状态栏右端的状态灯（状态变化才重绘，避免闪烁与干扰输入）。"
  (ignore-errors (cli-self-iteration-refresh-status)))

(defun cli-render-input (drawn-rows prefix label text &key cursor hint (cursor-row nil) layout-text)
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
    (push (list :start *cli-input-start-y* :cy cy :back back
                  :abs (and *cli-input-start-y*
                            (win32-set-cursor-position *cli-input-start-y* 0)
                            t)
                  :rows drawn-rows :crow cursor-row)
            *render-trace*)
    (when (> (length *render-trace*) 200)
      (setf *render-trace* (subseq *render-trace* 0 200)))
    (unless (and *cli-input-start-y*
                   (win32-set-cursor-position *cli-input-start-y* 0))
      (when (plusp back)
        (format t "~C[~DF" esc back)))
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
      (let ((width (console-width))
            (layout (or layout-text text)))
        (multiple-value-bind (rows crow ccol endrow endcol)
            (cli-text-rows (or layout "") width
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
            (let* ((real-y (nth-value 0 (win32-console-screen-info)))
                   (real-x (nth-value 2 (win32-console-screen-info)))
                   ;; 延迟换行：模型认为光标已换到下一行（endcol=0），实际还停在行尾
                   (pending (and (zerop endcol) (plusp (or real-x 0))))
                   (eff-end-row (if pending (max 0 (1- endrow)) endrow))
                   (col (1+ (max 0 (min ccol (1- width)))))
                   (up (- eff-end-row crow)))
              (when (plusp up)
                (format t "~C[~DA" esc up))
              (format t "~C[~DG" esc col)
              (finish-output)
              ;; 用实测光标行重新校准块首行：滚屏 / 延迟换行后旧锚点会失效，
              ;; 每帧校准一次，错误就不会累积成「删除一行却新增多行」。
              (when (and real-y (>= real-y 0))
                (setf *cli-input-start-y* (max 0 (- real-y eff-end-row))))
              (values (1+ eff-end-row) crow))))))))

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
(defparameter *paste-replay-ms* 400
  "粘贴可能被终端重复投递（整段 burst 之后再逐字符重放一遍）的判定窗口（毫秒）：
间隔小于该值的续接字符若正好等于粘贴块的下一个字符，就当作重放丢弃，
避免同一段文字被写进两份（屏幕上表现为输入行越画越长）。")

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

;;; SBCL 的 (coerce adjustable-char-vector 'string) 对带 fill-pointer 的可调向量
;;; 会直接返回同一个对象（eq 为真），随后清空 fill-pointer 会连带清空结果。
;;; 输入缓冲必须在「快照」时复制一份独立字符串，否则 Ctrl+E 展开后文本会被吞掉。
(defun input-buffer->string (buf)
  (if (and (array-has-fill-pointer-p buf)
           (typep buf '(array character (*))))
      (subseq buf 0 (fill-pointer buf))
      (coerce buf 'string)))

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
  ;; 记录本行输入区的起始行：重绘 / 提交时用「实测光标行 - 起始行」精确定位，
  ;; 折行或宽字符下也不会因上移不足而残留旧行（表现就是凭空多出一行）。
  ;; 记录本行输入区块首行。这里之后不要再把它置 nil，
  ;; 否则重绘会退回「相对上移行数」估算，折行后就会残留重复行。
  (setf *cli-input-start-y* (nth-value 0 (win32-console-screen-info)))
  (unless prefix-printed
    (when prefix (format t "~A" prefix) (finish-output)))
  (setf *cli-indicator-y* nil)
  (let* ((typed (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
         (paste nil)
         (paste-parts 0)
         (pasted (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
         (edit-mode nil)
         (edit-buf "")
         (edit-cursor 0)
         (edit-paste-start nil)
         (edit-paste-end nil)
         (drawn-rows 1)
          (drawn-cursor-row 0)
         (last-back-time 0)
         (last-paste-time 0)
         (suffix-attached nil)
         (prefix-attached nil)
         (last-time (get-internal-real-time))
          (last-char-time (get-internal-real-time))
          (replay-skipped 0)
         (done nil)
         (result nil))
    (labels
        ((ms-since (t0)
           (* 1000.0 (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
         (elapsed-ms ()
           (ms-since last-time))
         (paste-ongoing-p ()
           "这一批字符是否仍属于正在进行的那次粘贴：在续接窗口内，或输入队列仍有积压。"
           (and paste
                (or (< (ms-since last-paste-time) *paste-continuation-ms*)
                    (console-pending-char-p))))
         (pending-soon-p ()
           "队列这一刻取空了，但多行粘贴可能被终端拆成「先到换行、后到下一行」：
再观察几轮，真有后续字符就说明这一批属于粘贴而不是回车提交。"
           (dotimes (i *paste-grace-polls*)
             (when (console-pending-char-p) (return-from pending-soon-p t))
             (sleep 0.01))
           nil)
         (paste-text ()
           (string-right-trim (list #\Newline #\Return) (or paste "")))
         (paste-label ()
           (let ((base (paste-summary-label (paste-text))))
             (if (> paste-parts 1)
                 (format nil "~A · ~D 段" base paste-parts)
                 base)))
         (paste-body ()
           ;; 依次拼接：粘贴前输入的正文 + 粘贴块 + 粘贴后补写的文字。
           ;; 只有「真实存在输入间隔」的边界才补换行：同一次粘贴被终端拆成多批时，
           ;; 字符会先落进 typed / pasted，若无条件插换行就会凭空多出空行、
           ;; 把行首字符挤到下一行（多行粘贴内容被改乱的主因）。
           (let* ((tp (input-buffer->string typed))
                  (p (paste-text))
                  (a (input-buffer->string pasted))
                  (head (if (or prefix-attached (zerop (length tp)))
                            tp
                            (concatenate 'string tp (string #\Newline))))
                  (tail (if (plusp (length a))
                            (concatenate 'string
                                         (if (or suffix-attached (zerop (length p)))
                                             ""
                                             (string #\Newline))
                                         a)
                            "")))
             (concatenate 'string head p tail)))
         (current-text ()
           (cond (edit-mode edit-buf)
                 (paste (input-buffer->string pasted))
                 (t (input-buffer->string typed))))
         (current-label ()
           (cond (edit-mode nil)
                 (paste (paste-label))
                 (t nil)))
         (paste-display ()
           "返回 (values 着色文本 纯文本影子)：已输入正文 + 占位符 + 补写文字内联成一条。"
           (let* ((tp (input-buffer->string typed))
                  (lb (paste-label))
                  (sfx (input-buffer->string pasted))
                  (gap (if (and (plusp (length tp))
                                (not (member (char tp (1- (length tp)))
                                             '(#\Space #\Tab #\Newline))))
                           " "
                           "")))
             (values (concatenate 'string tp gap (ui-dim lb) sfx)
                     (concatenate 'string tp gap lb sfx))))
         (current-hint ()
            "只保留编辑模式提示：普通 / 粘贴态的提示会另起一行，"
            "退格触发重绘时就表现为「删除却新增一行」。提示文案见 /help。"
            (cond (edit-mode *edit-hint-edit*)
                  (t nil)))
          (display-plain ()
            (if paste
                (nth-value 1 (paste-display))
                (input-buffer->string typed)))
          (repaint-tail (old-plain)
            "把光标从旧末尾移到新末尾并清掉尾部：不需要知道输入块起点，
因此折行、滚屏、窗口缩放都不会残留旧行（退格删除时最稳）。"
            (let* ((new-plain (display-plain))
                   (w (max 1 (console-width)))
                   (pw (display-width* (or prefix "")))
                   (old (multiple-value-list
                         (cli-text-rows old-plain w :prefix-width pw)))
                   (new (multiple-value-list
                         (cli-text-rows new-plain w :prefix-width pw)))
                   ;; 旧末尾行必须用「控制台真实光标行」：文字刚好写满一行时，
                   ;; 终端处于延迟换行状态（光标仍在行尾），模型会多算一行。
                   (cy (nth-value 0 (win32-console-screen-info)))
                   (blk-start *cli-input-start-y*)
                   (o-row (or (and cy blk-start (>= cy blk-start)
                                  (< (- cy blk-start) 4000)
                                  (- cy blk-start))
                              (nth 3 old)))
                   (n-row (nth 3 new))
                   (n-col (nth 4 new))
                   (esc (code-char 27)))
              (cond
                ;; 新末尾反而更靠下（理论上不会发生）→ 退回整块重绘
                ((> n-row o-row) (render))
                (t
                 (let ((up (- o-row n-row)))
                   (when (plusp up)
                     (format t "~C[~DA" esc up))
                   (format t "~C[~DG" esc (1+ (max 0 (min n-col (1- w)))))
                   (format t "~C[J" esc)
                   (setf drawn-rows (1+ n-row)
                         drawn-cursor-row n-row)
                   (finish-output))))))
          (erase-last-char (w)
            "只擦掉光标左侧最后一个显示宽度为 W 的字符，不做任何「上移 N 行」的行数计算，
因此折行、满行、滚屏、窗口缩放都不会错行；最后统一 ESC[J 清掉尾部。
（输入区永远是屏幕最后一块内容，清到尾不会误伤历史。）"
            (let* ((esc (code-char 27))
                   (cols (max 1 (console-width)))
                   (cx (nth-value 2 (win32-console-screen-info))))
              (cond
                ;; 同一行：左移 W 覆盖掉该字符，再退回新末尾
                ((and cx (>= cx w))
                 (format t "~C[~DD" esc w)
                 (dotimes (i w) (write-char #\Space))
                 (format t "~C[~DD" esc w))
                ;; 光标已在行首：字符在上面的行尾，上移一行覆盖
                (t
                 (format t "~C[1A" esc)
                 (format t "~C[~DG" esc (max 1 (1+ (- cols w))))
                 (dotimes (i w) (write-char #\Space))
                 (format t "~C[~DD" esc w)))
              (format t "~C[J" esc)
              (finish-output)
              (multiple-value-bind (rows crow ccol endrow endcol)
                  (cli-text-rows (display-plain) cols
                                 :prefix-width (display-width* (or prefix "")))
                (declare (ignore crow ccol endcol))
                (setf drawn-rows rows
                      drawn-cursor-row endrow))))
          (render ()
            (multiple-value-bind (styled plain)
                (if paste
                    (paste-display)
                    (values (current-text) (current-text)))
              (multiple-value-bind (rows crow)
                  (cli-render-input drawn-rows prefix nil styled
                                    :layout-text plain
                                    :cursor (and edit-mode edit-cursor)
                                    :hint (current-hint)
                                    :cursor-row (if *cli-input-start-y* nil drawn-cursor-row))
                (setf drawn-rows rows
                      drawn-cursor-row crow))))
         (flush-notices-above ()
           ;; 自省提示：插到状态栏上方，状态栏与输入内容都原样保留。
           (let ((items (and (fboundp 'self-iteration-drain-notices)
                             (self-iteration-drain-notices))))
             (when items
               (let* ((esc (code-char 27))
                      (has-status (and *cli-status-line-text* *cli-input-start-y*))
                      (base (if has-status (1- *cli-input-start-y*) *cli-input-start-y*)))
                 (unless (and base (win32-set-cursor-position base 0))
                   (when (plusp drawn-cursor-row)
                     (format t "~C[~DA" esc drawn-cursor-row)))
                 (format t "~C" #\Return)
                 (format t "~C[J" esc)
                 (finish-output)
                 (dolist (item items)
                   (format t "~A ~A~%" (ui-tag-info "自省") item))
                 (when has-status
                   (format t "~A~%" *cli-status-line-text*))
                 (finish-output)
                 (setf *cli-input-start-y* (nth-value 0 (win32-console-screen-info))
                       *cli-status-row* (and has-status
                                             (1- (nth-value 0 (win32-console-screen-info))))
                       drawn-rows 1
                       drawn-cursor-row 0)
                 (render)))))
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
           (let* ((body (cond (edit-mode edit-buf)
                              (paste (paste-body))
                              (t (input-buffer->string typed))))
                  (plain (string-trim '(#\Space #\Tab #\Newline #\Return)
                                      (or body "")))
                  ;; 普通提问：把刚绘制的输入块整块擦掉，只保留 run-agent 打印的
                  ;; 浅色背景回显；/命令 与 ,表达式 仍保留原始输入行。
                  (command-like (and (plusp (length plain))
                                     (member (char plain 0) '(#\/ #\,)))))
             (if command-like
                 (format t "~%")
                 (cli-erase-input-block drawn-cursor-row))
             (finish-output)
             ;; 去掉尾部空白 / 换行：编辑模式里习惯性多按一次回车时，
             ;; 用户消息回显会凭空多出一条空的「用户行」。
             (let ((r (or body "")))
               (setf result (string-right-trim '(#\Space #\Tab #\Newline #\Return)
                                               (string-left-trim '(#\Newline #\Return) r))
                     done t))))
         (reset-all ()
           (setf (fill-pointer typed) 0
                 (fill-pointer pasted) 0
                 paste nil
                 paste-parts 0
                 suffix-attached nil
                 prefix-attached nil
                 edit-buf ""
                 edit-cursor 0
                 edit-paste-start nil
                 edit-paste-end nil
                 edit-mode nil
                 last-back-time 0
                 last-paste-time 0))
         (add-paste (text &key (new-segment t) (definite nil))
           (let ((absorbed nil))
             (setf prefix-attached nil)
             (when (and text (plusp (length text))
                ;; 同一段文本在极短时间内被重复投递（终端重放）时忽略，避免拼接两份。
                (not (and paste (string= text paste)
                          (< (ms-since last-paste-time) 1500))))
               ;; 同一次粘贴被终端拆成多批时，粘贴前刚敲进 typed 的字其实属于这一段，
               ;; 直接吸收进粘贴块并标记「紧邻」，拼接时就不会凭空插一个换行。
               (when (and (null paste)
                          (not definite)
                          (plusp (fill-pointer typed))
                          ;; 只有「终端把同一段粘贴拆成多批、第一批先落进 typed」
                          ;; 这种毫秒级衔接才允许吸收；人手打字后粘贴必须保持独立前缀。
                          (< (ms-since last-char-time) *paste-absorb-ms*)
                          (console-pending-char-p))
                 (setf paste (input-buffer->string typed)
                       (fill-pointer typed) 0
                       absorbed t
                       prefix-attached t))
               (when (and new-segment (plusp (fill-pointer pasted)))
                 ;; 上一次粘贴之后补写的内容先并入上一段粘贴，保证新粘贴接在它后面（顺序不乱）。
                 (let ((p (or paste "")))
                   (setf paste (concatenate 'string p
                                            (if (and (plusp (length p))
                                                     (not suffix-attached)
                                                     (not (char= (char p (1- (length p)))
                                                                 #\Newline)))
                                                (string #\Newline)
                                                "")
                                            (input-buffer->string pasted))
                         (fill-pointer pasted) 0
                         suffix-attached nil)))
               (when new-segment (incf paste-parts))
               ;; 新的粘贴段如果含换行、而已有粘贴内容不以换行结尾，就先补一个换行；
               ;; 否则「之前打的字 / 上一段粘贴」会和这次粘贴的第一行粘在一起。
               ;; 同一次粘贴被终端拆成多批时 new-segment 为 nil，不会插入额外换行；
               ;; 刚刚把 typed 吸收进粘贴块时（absorbed）也不能再补，否则会多出空行。
               (let* ((prev (or paste ""))
                      (sep (if (and new-segment
                                    (not absorbed)
                                    (find #\Newline text)
                                    (plusp (length prev))
                                    (not (char= (char prev (1- (length prev)))
                                                #\Newline)))
                               (string #\Newline)
                               "")))
                 (setf paste (concatenate 'string prev sep text)))
               (setf last-back-time 0
                     last-paste-time (get-internal-real-time))
               (render))))
         (line-start (i)
           (1+ (or (position #\Newline edit-buf :end i :from-end t) -1)))
         (line-end-of (i)
           (or (position #\Newline edit-buf :start i) (length edit-buf)))
         (buf-insert (s)
            (when (plusp (length s))
              (let ((p edit-cursor)
                    (len (length s))
                    (at-end (= edit-cursor (length edit-buf))))
                (when edit-paste-start
                  (cond ((<= p edit-paste-start)
                         (incf edit-paste-start len)
                         (incf edit-paste-end len))
                        ((< p edit-paste-end)
                         (incf edit-paste-end len))))
                (setf edit-buf (concatenate 'string
                                            (subseq edit-buf 0 edit-cursor) s
                                            (subseq edit-buf edit-cursor))
                      edit-cursor (+ edit-cursor (length s)))
                (if at-end
                    ;; 在末尾追加：直接回显字符，不再整块重绘（避免折行处错行）
                    (progn
                      (write-string s)
                      (finish-output)
                      (multiple-value-bind (rows crow ccol endrow endcol)
                          (cli-text-rows edit-buf (console-width)
                                         :prefix-width (display-width* (or prefix ""))
                                         :cursor edit-cursor)
                        (declare (ignore crow ccol endcol))
                        (setf drawn-rows rows
                              drawn-cursor-row endrow)))
                    (render)))))
          (buf-back ()
            (when (plusp edit-cursor)
              (let* ((at-end (= edit-cursor (length edit-buf)))
                     (del-w (and at-end
                                 (cli-char-width (char edit-buf (1- edit-cursor))))))
                (let ((p (1- edit-cursor)))
                  (when edit-paste-start
                    (cond ((< p edit-paste-start)
                           (decf edit-paste-start)
                           (decf edit-paste-end))
                          ((< p edit-paste-end)
                           (decf edit-paste-end)))))
                (setf edit-buf (concatenate 'string
                                            (subseq edit-buf 0 (1- edit-cursor))
                                            (subseq edit-buf edit-cursor))
                      edit-cursor (1- edit-cursor))
                (if at-end
                    ;; 末尾退格：只擦掉光标左边那个字符，不做整块重绘
                    (erase-last-char del-w)
                    (render)))))
          (buf-delete ()
           (when (< edit-cursor (length edit-buf))
             (let ((p edit-cursor))
               (when edit-paste-start
                 (cond ((< p edit-paste-start)
                        (decf edit-paste-start)
                        (decf edit-paste-end))
                       ((< p edit-paste-end)
                        (decf edit-paste-end)))))
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
         (set-buffer (buf str)
           (setf (fill-pointer buf) 0)
           (loop for ch across (or str "") do (vector-push-extend ch buf)))
         (start-edit ()
           ;; 展开成编辑缓冲：正文 / 粘贴块 / 补写按行拼接，
           ;; 同时记住「粘贴块」在编辑缓冲里的起止位置。
           (let ((buf "") (pstart nil) (pend nil))
             (let ((tp (input-buffer->string typed)))
               (when (plusp (length tp)) (setf buf tp)))
             (when paste
               (let ((p (paste-text)))
                 (when (plusp (length p))
                   (when (and (plusp (length buf)) (not prefix-attached))
                     (setf buf (concatenate 'string buf (string #\Newline))))
                   (setf pstart (length buf))
                   (setf buf (concatenate 'string buf p))
                   (setf pend (length buf)))))
             (let ((sfx (input-buffer->string pasted)))
               (when (plusp (length sfx))
                 (when (and (plusp (length buf)) (not suffix-attached))
                   (setf buf (concatenate 'string buf (string #\Newline))))
                 (setf buf (concatenate 'string buf sfx))))
             (setf edit-buf buf
                   edit-cursor (length buf)
                   edit-paste-start pstart
                   edit-paste-end pend
                   edit-mode t
                   (fill-pointer typed) 0
                   (fill-pointer pasted) 0
                   paste nil
                   paste-parts 0
                   suffix-attached nil
                   prefix-attached nil
                   last-back-time 0)
             (render)))
         (end-edit ()
           ;; Esc 退出：只把「单行模式下粘贴进来的区间」还原成占位符；
           ;; 手写内容、以及编辑模式里修改过的文字保持展开。
           (let* ((start edit-paste-start)
                  (end edit-paste-end)
                  (active (and start end (< start end))))
             (if active
                 (let* ((pre (subseq edit-buf 0 start))
                        (mid (subseq edit-buf start end))
                        (sfx (subseq edit-buf end)))
                   (when (and (plusp (length pre))
                              (char= (char pre (1- (length pre))) #\Newline))
                     (setf pre (subseq pre 0 (1- (length pre)))))
                   (when (and (plusp (length sfx)) (char= (char sfx 0) #\Newline))
                     (setf sfx (subseq sfx 1)))
                   (set-buffer typed pre)
                   (set-buffer pasted sfx)
                   (setf paste mid
                         paste-parts 1))
                 (progn
                   (set-buffer typed edit-buf)
                   (set-buffer pasted "")
                   (setf paste nil
                         paste-parts 0)))
              (setf edit-mode nil
                    edit-paste-start nil
                    edit-paste-end nil
                    prefix-attached t
                    suffix-attached t
                    last-back-time 0)
             (render)))
         (paste-backspace ()
            (let ((old (display-plain))
                  (now (get-internal-real-time)))
              (cond
                ;; 1) 删掉粘贴块之后手动输入的字：只擦掉光标左边那一个字符
                ((plusp (fill-pointer pasted))
                 (let* ((p (input-buffer->string pasted))
                        (w (cli-char-width (char p (1- (length p))))))
                   (decf (fill-pointer pasted))
                   (setf last-back-time 0)
                   (erase-last-char w)))
                ;; 2) 光标已在粘贴块结尾，600ms 内第二次退格 = 整段粘贴一起删除
                ((and (plusp last-back-time)
                      (< (ms-since last-back-time) *paste-double-back-ms*))
                 (setf paste nil
                       paste-parts 0
                       (fill-pointer pasted) 0
                       last-back-time 0)
                 (repaint-tail old))
                ;; 3) 第一次退格只「待命」
                (t (setf last-back-time now)))))
          (handle-backspace ()
            (cond (edit-mode (buf-back))
                  (paste (paste-backspace))
                  ((plusp (fill-pointer typed))
                   (let* ((buf (input-buffer->string typed))
                          (w (cli-char-width (char buf (1- (length buf))))))
                     (decf (fill-pointer typed))
                     (erase-last-char w)))))
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
                     (add-paste clean :definite t))))))
         (handle-char (ch)
            (let ((c (code-char ch))
                  (gap (ms-since last-char-time)))
              (setf last-char-time (get-internal-real-time))
              (cond
                (edit-mode (buf-insert (string c)))
                (paste
                 (let* ((mine (input-buffer->string pasted))
                        (np (length mine))
                        (p (or paste "")))
                   (cond
                     ;; 粘贴可能被终端重复投递：整段 burst 之后再逐字符重放一遍。
                     ;; 已输入内容仍是粘贴块前缀、新字符等于对应位置字符、间隔极短 → 丢弃。
                     ((and (< (+ np replay-skipped) (length p))
                           (string= mine (subseq p 0 np))
                           (char= c (char p (+ np replay-skipped)))
                           (< gap *paste-replay-ms*))
                      (incf replay-skipped))
                      (t
                       (setf replay-skipped 0)
                       ;; 粘贴洪泛被终端拆成单字符批次时，这个字符仍属于同一段粘贴，
                       ;; 拼接时不能再插换行，否则行首字符会被挤到下一行。
                       (when (zerop np)
                         (setf suffix-attached (and (paste-ongoing-p) t)))
                       (vector-push-extend c pasted)
                       (setf last-back-time 0)
                      ;; 粘贴后的续写不再整块重绘：字符直接回显，折行交给终端处理。
                      ;; 整块重绘只保留在粘贴 / 退格 / 编辑等低频时机，从结构上杜绝堆行。
                      (write-char c)
                      (finish-output)
                      (multiple-value-bind (styled plain) (paste-display)
                        (declare (ignore styled))
                        (multiple-value-bind (rows crow ccol endrow endcol)
                            (cli-text-rows plain (console-width)
                                           :prefix-width (display-width* (or prefix "")))
                          (declare (ignore crow ccol endcol))
                          (setf drawn-rows rows
                                drawn-cursor-row endrow)))))))
                (t (vector-push-extend c typed)
                   (echo-char c)))))
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
                   ((or (and (= vk *vk-v*) ctrl-p)
                        (and (= vk *vk-insert*) (logtest ctrl *ctrl-shift*)))
                    (handle-clipboard))
                   ((and (= ch *vk-ctrl-u*) ctrl-p)
                    (if edit-mode
                        (setf edit-buf "" edit-cursor 0
                              edit-paste-start nil edit-paste-end nil)
                        (reset-all))
                    (render))
                   (edit-mode
                    (handle-edit-key vk ch))
                   ((and (> ch 31) (/= vk *vk-tab*) (plusp ch))
                    (handle-char ch))))))))
      (let ((empty-polls 0))
        (loop until done
              do (when (and (> (ms-since last-char-time) 400) (null paste))
                   (flush-notices-above))
                 (let ((recs (ignore-errors (%console-fetch-records 256))))
                   (cond
                     ((eq recs :timeout)
                      (when (> (ms-since last-char-time) 300)
                        (cli-self-iteration-animate))
                      (sleep 0.01))
                     ((null recs)
                      (cond
                        ;; 防死锁：在 eval_lisp 自测环境下，mock 的 %console-fetch-records
                        ;; 消费完预设记录后会持续返回 nil；若超过 3 次空轮询仍未触发 submit，
                        ;; 自动提交当前缓冲区（或返回 :eof）并退出循环，绝不无限卡死。
                        ((and (boundp '*in-eval-lisp*)
                              (symbol-value '*in-eval-lisp*))
                         (if (> (incf empty-polls) 3)
                             (if (or edit-mode paste (plusp (fill-pointer typed)))
                                 (submit)
                                 (setf result :eof done t))
                             (sleep 0.005)))
                        ((null (%console-input-handle))
                         (setf result :eof done t))
                        (t
                         (cli-self-iteration-animate)
                         (sleep 0.01))))
                     (t
                      (setf empty-polls 0)
                      (let* ((text (batch-text recs))
                             (nchars (length text))
                             (newline-p (and (find #\Newline text) t))
                             (burst (and *cli-collapse-paste*
                                         (cond
                                           ((>= nchars *paste-burst-chars*) t)
                                           ((and newline-p (> nchars 1)) t)
                                           (newline-p (or (paste-ongoing-p)
                                                          (< (ms-since last-paste-time) *paste-split-window-ms*)
                                                          (console-pending-char-p)
                                                          ;; 队列可能恰好在这一瞬间取空：再等三十毫秒看是否有后续字符，
                                                          ;; 有就按多行粘贴处理，绝不把一段粘贴拆成「第一行先提交」。
                                                          (pending-soon-p)))
                                           ;; 输入队列有积压且一批就有多个字符 → 属于同一次洪泛（粘贴开始或继续）
                                           ((and (> nchars 1)
                                                 (console-pending-char-p)
                                                 (or paste (>= nchars 8))) t)
                                           (t (and (paste-ongoing-p) (> nchars 1)))))))
                        (setf last-time (get-internal-real-time))
                        (if burst
                            (if edit-mode
                                (buf-insert text)
                                (add-paste text :new-segment (not (paste-ongoing-p))))
                            (dolist (rec recs)
                              (unless done (handle-record rec)))))))))))
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

(defun cli-status-line-with-indicator (line)
  "把自省状态灯拼到状态栏同一行的最右侧；空间不足时紧跟在状态栏后面。"
  (let* ((ind (and (fboundp 'self-iteration-indicator)
                   (ignore-errors (self-iteration-indicator))))
         (w (max 2 (console-width)))
         (target (1- w))
         (lw (if (stringp line) (display-width* line) 0))
         (iw (if ind (display-width* ind) 0)))
    (cond
      ((null line) nil)
      ((null ind) line)
      ((>= (- target lw iw) 1)
       (concatenate 'string line
                    (make-string (- target lw iw) :initial-element #\Space)
                    ind))
      (t (concatenate 'string line "  " ind)))))

(defun cli-prompt-repaint ()
  "读取输入前重绘底部状态栏（右侧拼上自省状态灯）。
主循环是常驻的已编译代码，热重载改不了其中已经执行到的语句；
而 read-cli-input 的调用是晚绑定的，重载即生效，所以把状态栏放在这里：
先擦掉外层刚打印的 `You >` 提示符，打印状态栏，再重印提示符。
状态灯只在这里随状态栏静态打印，不对输入行做任何光标操作。"
  (ignore-errors (cli-paste-enable))
  (setf *cli-last-print-source* nil
        *cli-status-line-width* 0
        *cli-indicator-y* nil)
  (when (and (fboundp 'ui-color-on-p) (ignore-errors (ui-color-on-p)))
    (let* ((line (and (fboundp 'ctx-status-render)
                      (funcall 'ctx-status-render *session-history*)))
           (composed (cli-status-line-with-indicator line)))
      ;; \r + ESC[2K：回到行首并整行擦除（清掉已打印的提示符）
      (format t "~C~C[2K" #\Return (code-char 27))
      (let ((row (nth-value 0 (win32-console-screen-info))))
        (when composed (format t "~A~%" composed))
        (setf *cli-status-row* row
              *cli-status-line-text* composed
              *cli-status-last* (and (fboundp 'self-iteration-indicator)
                                     (ignore-errors (self-iteration-indicator)))))
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

      ((or (string-equal trimmed "/self")
           (and (> (length trimmed) 6)
                (string-equal "/self " (subseq trimmed 0 6))))
       (if (fboundp 'self-iteration-handle-command)
           (funcall 'self-iteration-handle-command (trim-whitespace (subseq trimmed 5)))
            (format t "  ~A 自省模块未加载。~%~%" (ui-tag-err "失败")))
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
          do (when (fboundp 'self-iteration-flush-notices)
               (funcall 'self-iteration-flush-notices))
             (format t "~A " (ui-colorize "1;36" "You >"))
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
            (when (fboundp 'self-iteration-note-activity)
              (funcall 'self-iteration-note-activity))
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
                        ;; 流式模式下正文已经边到边渲染（见 llm-client 的 md-stream-*），
                        ;; 这里不再重复打印，避免同一答案出现两遍。
                        (let ((streamed (and (fboundp 'stream-output-started-p)
                                             (funcall 'stream-output-started-p))))
                          (if cancelled
                              (format t "~%~A ~A~%    （历史仍保留 ~D 条消息，可直接继续提问；输入 /clear 可清空）~%~%"
                                      (ui-tag-warn "中断")
                                      (if streamed
                                          ""
                                          (if (fboundp 'render-markdown)
                                              (funcall 'render-markdown answer)
                                              answer))
                                      (length *session-history*))
                              (if streamed
                                  (format t "~%")
                                  (format t "~%~A~%~A~%~%" (ui-colorize "1;32" "Agent >")
                                          (if (fboundp 'render-markdown)
                                              (funcall 'render-markdown answer)
                                              answer)))))
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

(defun cli-erase-input-block (cursor-row)
  "把刚提交的输入块整块擦掉（回到块起点后清到屏幕底部），只保留随后打印的
浅色背景用户消息。仅在 VT 可用的裸模式下调用。
定位优先用控制台绝对坐标（起点行第 0 列），折行、滚屏、窗口缩放都不会残留旧行；
拿不到控制台信息时才退回相对上移的估算值。"
  (let* ((esc (code-char 27))
         (cy (nth-value 0 (win32-console-screen-info)))
         (start *cli-input-start-y*)
         (measured (and cy start (>= cy start) (< (- cy start) 4000) (- cy start)))
         (back (or measured
                   (and (integerp cursor-row) (>= cursor-row 0) cursor-row)
                   0)))
    (unless (and start (win32-set-cursor-position start 0))
      (format t "~C" #\Return)
      (when (plusp back)
        (format t "~C[~DA" esc back)))
    (format t "~C[J" esc)
    (finish-output)
    (setf *cli-input-start-y* nil))
  t)
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

