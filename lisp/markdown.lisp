;;;; lisp/markdown.lisp
;;;; 轻量级 Markdown → ANSI 终端渲染器（纯 Common Lisp，零依赖）
;;;;
;;;; 特性：
;;;;   1. 标题 / 列表 / 引用 / 代码块 / 行内样式
;;;;   2. 表格：按【显示宽度】对齐（中文=2 列、emoji=2 列），带边框
;;;;   3. CMD / GBK 等不支持 emoji 的终端：键帽数字、变体选择符、emoji 统一转成彩色文本标签

(in-package :cl-user)

(defparameter *md-color-mode* :auto
  "Markdown 颜色模式：:auto 自动检测终端 / t 强制开启 / nil 关闭。")

(defparameter *md-emoji-mode* :auto
  "emoji 处理：:auto 与 t 一律转成彩色文本标签（默认不显示 emoji）；nil 保留原样。")

(defparameter *md-code-inline-style* "33"
  "行内代码的 ANSI 样式：默认黄色前景、不填充背景，避免整段代码块变蓝。")

(defparameter *md-esc* (string (code-char 27))
  "ANSI 转义字符 ESC。")

;;; ── ANSI 基础 ──────────────────────────────────────────────

(defun md-color-on-p ()
  "判断是否启用 ANSI 颜色（复用 ui.lisp 的终端检测，支持 Windows CMD 自动开启 VT）。"
  (cond
    ((null *md-color-mode*) nil)
    ((eq *md-color-mode* t) t)
    ((fboundp 'ui-color-on-p) (funcall 'ui-color-on-p))
    (t (and (null (uiop:getenv "NO_COLOR"))
            (or (uiop:getenv "WT_SESSION")
                (uiop:getenv "TERM")
                (uiop:getenv "COLORTERM")
                (uiop:getenv "ConEmuANSI"))))))

(defun md-ascii-word-p (c)
  "ASCII 字母/数字判定（中文等宽字符不算词内字符）。"
  (let ((code (char-code c)))
    (or (<= 48 code 57) (<= 65 code 90) (<= 97 code 122))))

(defun md-lisp-symbol-p (s)
  "判断文本是否像 Lisp 标识符（earmuff 变量、my-func-name 等）。
  此类文本在 * 或 _ 强调解析时保持字面量，避免星号被当作斜体标记吞掉。"
  (and (plusp (length s))
       (<= (length s) 64)
       (let ((has-sep nil) (ok t))
         (loop for c across s
               do (cond ((or (md-ascii-word-p c) (char= c #\*)) nil)
                        ((find c "-_+/=<>!?.") (when (or (char= c #\-) (char= c #\_))
                                                  (setf has-sep t)))
                        (t (setf ok nil) (return))))
         (and ok has-sep))))

(defun md-wrap (code text)
  (if (md-color-on-p)
      (concatenate 'string *md-esc* "[" code "m" text *md-esc* "[0m")
      text))

(defun md-bold (s) (md-wrap "1" s))
(defun md-italic (s) (md-wrap "3" s))
(defun md-underline (s) (md-wrap "4" s))
(defun md-gray (s) (md-wrap "90" s))
(defun md-red (s) (md-wrap "31" s))
(defun md-green (s) (md-wrap "32" s))
(defun md-yellow (s) (md-wrap "33" s))
(defun md-blue (s) (md-wrap "34" s))
(defun md-cyan (s) (md-wrap "36" s))

;;; ── 纯文本降级：emoji / 键帽数字 / 变体选择符 ─────────────

(defparameter *md-emoji-tags*
  '(("✅" "成功" "1;32") ("✔" "成功" "1;32") ("☑" "成功" "1;32") ("✓" "成功" "1;32")
    ("❌" "失败" "1;31") ("✘" "失败" "1;31") ("❎" "失败" "1;31")
    ("⚠" "警告" "1;33") ("❗" "警告" "1;33")
    ("❓" "问" "36") ("❔" "问" "36") ("ℹ" "提示" "36") ("💡" "提示" "1;36")
    ("🔥" "要点" "1;35") ("⭐" "*" "33") ("✨" "*" "33") ("🌟" "*" "33")
    ("🔁" "重载" "1;35") ("🔄" "重载" "1;35") ("🔃" "重载" "1;35")
    ("🔧" "工具" "1;34") ("🛠" "工具" "1;34") ("⚙" "配置" "34")
    ("🧪" "测试" "34") ("🔍" "搜索" "36")
    ("📄" "文件" "34") ("📝" "笔记" "36") ("📌" "备注" "36") ("📖" "文档" "36")
    ("📁" "目录" "34") ("📂" "目录" "34") ("🗂" "目录" "34")
    ("🗑" "删除" "1;31") ("🧹" "清理" "31")
    ("🚀" "启动" "1;36") ("👉" "->" "36") ("⏳" "等待" "2")
    ("🎉" "完成" "1;32") ("👋" "再见" "36") ("📦" "包" "34")
    ("🧠" "思考" "1;35") ("🎨" "样式" "35")
    ("🔒" "锁定" "33") ("🔓" "解锁" "32") ("📊" "统计" "36") ("🛡" "安全" "33"))
  "常见 emoji → 彩色文本标签映射（默认不再输出任何 emoji）。")

(defun md-emoji-clean-p ()
  "是否需要把 emoji 转成彩色文本标签（:auto 与 t 均转换；nil 保留原样）。"
  (not (null *md-emoji-mode*)))

(defun md-tag (label style)
  "输出彩色方括号标签；ui.lisp 缺失时退化为纯文本。"
  (if (fboundp 'ui-tag)
      (funcall 'ui-tag label style)
      (format nil "[~A]" label)))

(defun md-emoji-code-p (code)
  (or (<= #x1F000 code #x1FAFF)
      (<= #x2600 code #x27BF)
      (<= #x2B00 code #x2BFF)))

(defun md-clean-text (text)
  "把 emoji / 键帽数字 / 变体选择符统一转成彩色文本标签（不输出 emoji）。"
  (let ((n (length text))
        (clean-p (md-emoji-clean-p)))
    (with-output-to-string (out)
      (loop with i = 0
            while (< i n)
            do (let* ((ch (char text i))
                      (code (char-code ch))
                      (rep (and clean-p
                                (assoc (string ch) *md-emoji-tags* :test #'string=))))
                 (cond
                   ;; 键帽数字：'5' + 可选 U+FE0F + U+20E3 → "5."
                   ((and (or (digit-char-p ch) (char= ch #\#) (char= ch #\*))
                         (let ((j (1+ i)))
                           (when (and (< j n) (= (char-code (char text j)) #xFE0F))
                             (incf j))
                           (and (< j n) (= (char-code (char text j)) #x20E3))))
                    (write-string (if (digit-char-p ch)
                                      (format nil "~C." ch)
                                      (format nil "[~C]" ch))
                                  out)
                    (setf i (+ i (if (and (< (1+ i) n)
                                          (= (char-code (char text (1+ i))) #xFE0F))
                                     3 2))))
                   ;; 变体选择符 / ZWJ / 孤立键帽 → 丢弃
                   ((or (= code #xFE0F) (= code #xFE0E) (= code #x200D) (= code #x20E3))
                    (incf i))
                   ;; 已知 emoji → ASCII
                   (rep (write-string (md-tag (second rep) (third rep)) out) (incf i))
                   ;; 未知 emoji（CMD 下必乱码）→ 丢弃
                   ((and clean-p (md-emoji-code-p code)) (incf i))
                   (t (write-char ch out) (incf i))))))))

;;; ── 显示宽度（中文 / emoji 记 2 列） ───────────────────────

(defun md-wide-code-p (code)
  (or (<= #x1100 code #x115F)
      (<= #x2E80 code #xA4CF)
      (<= #xAC00 code #xD7A3)
      (<= #xF900 code #xFAFF)
      (<= #xFE30 code #xFE4F)
      (<= #xFF00 code #xFF60)
      (<= #xFFE0 code #xFFE6)
      (<= #x2600 code #x27BF)
      (<= #x2B00 code #x2BFF)
      (<= #x1F000 code #x1FAFF)))

(defun md-zero-code-p (code)
  (or (<= #x0300 code #x036F)
      (<= #x200B code #x200F)
      (<= #xFE00 code #xFE0F)
      (= code #x20E3)))

(defun md-display-width (s)
  "计算终端显示宽度（ANSI 序列记 0 列，中文/emoji 记 2 列）。"
  (let ((n (length s))
        (w 0))
    (loop with i = 0
          while (< i n)
          do (let ((ch (char s i)))
               (if (char= ch (code-char 27))
                   (let ((end (position #\m s :start i)))
                     (setf i (if end (1+ end) n)))
                   (let ((code (char-code ch)))
                     (cond ((md-zero-code-p code))
                           ((md-wide-code-p code) (incf w 2))
                           (t (incf w)))
                     (incf i)))))
    w))

;;; ── 行内解析 ──────────────────────────────────────────────

(defun md-inline (text)
  "渲染行内 Markdown：`代码`、**粗体**、*斜体*、~~删除线~~、[链接](url)。"
  (with-output-to-string (out)
    (let ((i 0)
          (n (length text)))
      (labels ((emit (s) (write-string s out))
               (has-at-p (prefix pos)
                 (and (<= (+ pos (length prefix)) n)
                      (string= prefix text :start2 pos
                                      :end2 (+ pos (length prefix))))))
        (loop while (< i n)
              do (let ((ch (char text i)))
                   (cond
                     ((char= ch #\`)
                      (let ((end (position #\` text :start (1+ i))))
                        (if end
                            (progn (emit (md-wrap *md-code-inline-style* (subseq text (1+ i) end)))
                                   (setf i (1+ end)))
                            (progn (emit (string ch)) (incf i)))))
                     ((has-at-p "**" i)
                      (let ((end (search "**" text :start2 (+ i 2))))
                        (if end
                            (progn (emit (md-bold (md-inline (subseq text (+ i 2) end))))
                                   (setf i (+ end 2)))
                            (progn (emit "**") (incf i 2)))))
                     ((has-at-p "~~" i)
                      (let ((end (search "~~" text :start2 (+ i 2))))
                        (if end
                            (progn (emit (md-gray (md-inline (subseq text (+ i 2) end))))
                                   (setf i (+ end 2)))
                            (progn (emit "~~") (incf i 2)))))
                     ((or (char= ch #\*) (char= ch #\_))
                      (let* ((marker (string ch))
                             (end (search marker text :start2 (1+ i)))
                             (prev-ok (or (= i 0)
                                          (not (md-ascii-word-p (char text (1- i))))))
                             (next-ok (and end
                                           (or (>= (1+ end) n)
                                               (not (md-ascii-word-p (char text (1+ end))))))))
                        (if (and end (> end (1+ i)) prev-ok next-ok)
                            (if (md-lisp-symbol-p (subseq text (1+ i) end))
                                ;; Lisp 标识符：原样保留 *星号*，不渲染成斜体
                                (progn (emit (subseq text i (1+ end)))
                                       (setf i (1+ end)))
                                (progn (emit (md-italic (md-inline (subseq text (1+ i) end))))
                                       (setf i (1+ end))))
                            (progn (emit (string ch)) (incf i)))))
                     ((char= ch #\[)
                      (let* ((close (position #\] text :start (1+ i)))
                             (open (and close (position #\( text :start (1+ close))))
                             (fin (and open (position #\) text :start (1+ open)))))
                        (if fin
                            (progn
                              (emit (md-underline
                                     (md-blue (md-inline (subseq text (1+ i) close)))))
                              (emit (md-gray (format nil " (~A)" (subseq text (1+ open) fin))))
                              (setf i (1+ fin)))
                            (progn (emit "[") (incf i)))))
                     (t (emit (string ch)) (incf i)))))))))

;;; ── 行结构识别 ────────────────────────────────────────────

(defun md-split-lines (text)
  (let ((lines '())
        (start 0)
        (len (length text)))
    (loop
      (let ((nl (position #\Newline text :start start)))
        (if nl
            (progn (push (subseq text start nl) lines)
                   (setf start (1+ nl)))
            (progn (push (subseq text start len) lines)
                   (return)))))
    (nreverse lines)))

(defun md-prefix-p (prefix str)
  (let ((pl (length prefix)))
    (and (<= pl (length str))
         (string= prefix str :start2 0 :end2 pl))))

(defun md-leading-spaces (line)
  (let ((i 0)
        (n (length line)))
    (loop while (and (< i n) (member (char line i) '(#\Space #\Tab)))
          do (incf i))
    i))

(defun md-heading (line)
  "返回 (values 级别 文本)；非标题时级别为 0。"
  (let ((i 0)
        (n (length line)))
    (loop while (and (< i n) (char= (char line i) #\#)) do (incf i))
    (if (and (> i 0)
             (or (= i n) (char= (char line i) #\Space)))
        (values (min i 4) (string-left-trim '(#\Space #\Tab) (subseq line i)))
        (values 0 line))))

(defun md-hr-p (trimmed)
  (and (>= (length trimmed) 3)
       (let ((c (char trimmed 0)))
         (and (member c '(#\- #\* #\_))
              (every (lambda (ch) (or (char= ch c) (char= ch #\Space))) trimmed)))))

(defun md-quote-p (trimmed)
  (and (> (length trimmed) 0) (char= (char trimmed 0) #\>)))

(defun md-ulist-p (trimmed)
  (and (>= (length trimmed) 2)
       (member (char trimmed 0) '(#\- #\* #\+))
       (char= (char trimmed 1) #\Space)))

(defun md-olist (trimmed)
  (let ((dot (position #\. trimmed)))
    (when (and dot (> dot 0) (<= dot 3)
               (every #'digit-char-p (subseq trimmed 0 dot))
               (> (length trimmed) (1+ dot))
               (char= (char trimmed (1+ dot)) #\Space))
      dot)))

(defun md-table-p (trimmed)
  (and (> (length trimmed) 1) (char= (char trimmed 0) #\|)))

;;; ── 表格渲染（按显示宽度对齐） ────────────────────────────

(defun md-split-cells (line)
  "按 | 拆分单元格，去掉首尾空单元格。"
  (let ((cells '())
        (start 0)
        (n (length line)))
    (loop
      (let ((p (position #\| line :start start)))
        (push (string-trim '(#\Space #\Tab) (subseq line start (or p n))) cells)
        (if p (setf start (1+ p)) (return))))
    (let ((res (nreverse cells)))
      (when (and res (string= (first res) "")) (pop res))
      (when (and res (string= (car (last res)) "")) (setf res (butlast res)))
      res)))

(defun md-separator-cell-p (cell)
  (and (> (length cell) 0)
       (find #\- cell)
       (every (lambda (ch) (member ch '(#\- #\: #\Space))) cell)))

(defun md-separator-row-p (cells)
  (and cells (every #'md-separator-cell-p cells)))

(defun md-pad-to (s width)
  "右侧补空格到指定显示宽度。"
  (let ((delta (- width (md-display-width s))))
    (if (> delta 0)
        (concatenate 'string s (make-string delta :initial-element #\Space))
        s)))

(defun md-border-line (widths left mid right)
  (with-output-to-string (o)
    (write-string left o)
    (loop for w in widths
          for k from 0
          do (when (> k 0) (write-string mid o))
             (write-string (make-string (+ w 2) :initial-element #\─) o))
    (write-string right o)))

(defparameter *md-table-max-col-width* 36
  "单列最大显示宽度（超出则自动折行）。")

(defparameter *md-table-max-width* 92
  "整表最大显示宽度（含边框与内边距；超出时压缩最宽的列）。")

(defun md-split-words (s)
  "按空格切词（连续空格视为一个分隔）。"
  (let ((words '())
        (start nil)
        (n (length s)))
    (loop for i from 0 below n
          do (let ((ch (char s i)))
               (if (char= ch #\Space)
                   (when start
                     (push (subseq s start i) words)
                     (setf start nil))
                   (unless start (setf start i)))))
    (when start (push (subseq s start n) words))
    (nreverse words)))

(defun md-hard-split (s width)
  "按显示宽度逐字符硬折（不拆开中文 / emoji）。"
  (let ((lines '())
        (cur '())
        (cur-w 0))
    (flet ((flush ()
             (push (coerce (nreverse cur) 'string) lines)
             (setf cur nil cur-w 0)))
      (loop for ch across s
            do (let* ((code (char-code ch))
                      (w (cond ((md-zero-code-p code) 0)
                               ((md-wide-code-p code) 2)
                               (t 1))))
                 (when (and (> (+ cur-w w) width) (> cur-w 0))
                   (flush))
                 (push ch cur)
                 (incf cur-w w)))
      (flush))
    (nreverse lines)))

(defun md-wrap-text (s width)
  "按显示宽度折行：优先在空格处断行，只有超长单词才逐字符硬折。"
  (cond
    ((zerop (length s)) (list ""))
    ((<= (md-display-width s) width) (list s))
    (t
     (let ((lines '())
           (cur ""))
       (dolist (w (md-split-words s))
         (let ((cand (if (zerop (length cur))
                         w
                         (concatenate 'string cur " " w))))
           (cond
             ((<= (md-display-width cand) width)
              (setf cur cand))
             (t
              (when (> (length cur) 0) (push cur lines))
              (setf cur "")
              (dolist (piece (md-hard-split w width))
                (push piece lines))
              (when lines
                (setf cur (pop lines)))))))
       (when (> (length cur) 0) (push cur lines))
       (or (nreverse lines) (list ""))))))

(defun md-fit-widths (widths)
  "整表过宽时逐格压缩最宽的列（含边框与内边距一起计算，最低保留 6）。"
  (let* ((ws (copy-list widths))
         (n (length ws)))
    (flet ((total () (+ (reduce #'+ ws) (* 3 n) 1)))
      (loop while (and (> (total) *md-table-max-width*)
                       (> (reduce #'max ws) 6))
            do (let* ((maxw (reduce #'max ws))
                      (pos (position maxw ws)))
                 (setf (nth pos ws) (1- maxw)))))
    ws))

(defun md-render-table (lines)
  "把连续的表格行渲染成等宽对齐、可自动折行的表格。"
  (let* ((rows (mapcar #'md-split-cells lines))
         (sep (position-if #'md-separator-row-p rows))
         (head (when (and sep (> sep 0)) (subseq rows 0 sep)))
         (body (if sep (subseq rows (1+ sep)) rows))
         (all (append head body)))
    (if (null all)
        ""
        (let* ((ncols (apply #'max (mapcar #'length all)))
               (plain (mapcar (lambda (r)
                                (loop for k from 0 below ncols
                                      collect (or (nth k r) "")))
                              all))
               (widths (make-list ncols :initial-element 1)))
          (dolist (r plain)
            (loop for cell in r
                  for k from 0 below ncols
                  do (setf (nth k widths)
                           (max (nth k widths)
                                (min *md-table-max-col-width*
                                     (md-display-width cell))))))
          (setf widths (md-fit-widths widths))
          (with-output-to-string (out)
            (format out "~A~%" (md-border-line widths "┌" "┬" "┐"))
            (loop for r in plain
                  for idx from 0
                  do (progn
                       (let* ((chunks (loop for cell in r
                                            for k from 0 below ncols
                                            collect (md-wrap-text cell (nth k widths))))
                              (height (apply #'max (mapcar (lambda (c) (length c)) chunks))))
                         (loop for li from 0 below height
                               do (progn
                                    (write-string "│" out)
                                    (loop for k from 0 below ncols
                                          do (let ((rendered (md-inline (or (nth li (nth k chunks)) ""))))
                                               (write-string " " out)
                                               (write-string (md-pad-to rendered (nth k widths)) out)
                                               (write-string " │" out)))
                                    (terpri out))))
                       (when (and head (> (length head) 0)
                                  (= idx (1- (length head))))
                         (format out "~A~%" (md-border-line widths "├" "┼" "┤")))))
            (format out "~A" (md-border-line widths "└" "┴" "┘")))))))
;;; ── 主渲染入口 ────────────────────────────────────────────

(defun markdown-to-ansi (text)
  "把 Markdown 文本转换为适合终端显示的字符串。"
  (let ((lines (mapcar (lambda (l) (string-right-trim '(#\Return) l))
                       (md-split-lines (md-clean-text (or text "")))))
        (in-code nil)
        (lang ""))
    (with-output-to-string (out)
      (loop with rest = lines
            while rest
            do (let ((raw (pop rest)))
                 (let* ((trimmed (string-left-trim '(#\Space #\Tab) raw))
                        (hmv (multiple-value-list (md-heading raw)))
                        (hlevel (first hmv))
                        (htext (second hmv))
                        (pad (make-string (md-leading-spaces raw) :initial-element #\Space)))
                   (cond
                     ;; 1. 代码围栏
                     ((md-prefix-p "```" trimmed)
                      (if in-code
                          (progn (format out "~A~%" (md-gray "  └────────"))
                                 (setf in-code nil))
                          (progn
                            (setf in-code t
                                  lang (string-trim '(#\Space #\Tab) (subseq trimmed 3)))
                            (format out "~A~%"
                                    (md-gray (format nil "  ┌── ~A"
                                                     (if (zerop (length lang)) "code" lang)))))))
                     ;; 2. 代码块内容
                     (in-code
                      (format out "~A~%" (md-wrap "37" (format nil "  │ ~A" raw))))
                     ;; 3. 空行
                     ((zerop (length trimmed))
                      (format out "~%"))
                     ;; 4. 标题
                     ((> hlevel 0)
                      (let ((body (md-inline htext)))
                        (format out "~A~%"
                                (cond ((= hlevel 1) (md-wrap "1;4;36" (format nil "◆ ~A" body)))
                                      ((= hlevel 2) (md-wrap "1;36" (format nil "◇ ~A" body)))
                                      ((= hlevel 3) (md-wrap "36" (format nil "● ~A" body)))
                                      (t (md-wrap "36" (format nil "· ~A" body)))))))
                     ;; 5. 分割线
                     ((md-hr-p trimmed)
                      (format out "~A~%" (md-gray (make-string 52 :initial-element #\─))))
                     ;; 6. 引用
                     ((md-quote-p trimmed)
                      (let ((body (string-left-trim '(#\Space #\Tab #\>) (subseq trimmed 1))))
                        (format out "~A~%" (md-gray (format nil "  │ ~A" body)))))
                     ;; 7. 无序列表
                     ((md-ulist-p trimmed)
                      (format out "~A~%" (format nil "~A~A ~A"
                                                 pad (md-gray "•")
                                                 (md-inline (subseq trimmed 2)))))
                     ;; 8. 有序列表
                     ((md-olist trimmed)
                      (let* ((dot (md-olist trimmed))
                             (num (subseq trimmed 0 (1+ dot)))
                             (body (subseq trimmed (+ dot 2))))
                        (format out "~A~%" (format nil "~A~A ~A"
                                                   pad (md-cyan num) (md-inline body)))))
                     ;; 9. 表格：连续以 | 开头的行作为整体对齐
                     ((md-table-p trimmed)
                      (let ((block (list raw)))
                        (loop while (and rest
                                         (md-table-p (string-left-trim '(#\Space #\Tab) (first rest))))
                              do (push (pop rest) block))
                        (format out "~A~%" (md-render-table (nreverse block)))))
                     ;; 10. 普通段落
                     (t (format out "~A~%" (md-inline raw))))))))))

(defun render-markdown (text)
  "CLI 统一入口：渲染 Markdown；任何异常都降级为原文。"
  (handler-case (markdown-to-ansi (or text ""))
    (error () (or text ""))))

(defun print-markdown (text &optional (stream *standard-output*))
  (write-string (render-markdown text) stream)
  (finish-output stream))
