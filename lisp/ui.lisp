;;;; lisp/ui.lisp
;;;; 终端视觉层：纯文本提示标签 + ANSI 配色（不输出任何 emoji）。
;;;;
;;;; 设计：
;;;;   1. 所有提示统一为「[标签] 内容」形式，标签按语义着色：
;;;;      [成功] 绿 / [失败] 红 / [警告] 黄 / [提示] 青 / [配置] 蓝
;;;;   2. 颜色可用性只检测一次并缓存；Windows 下自动为控制台开启
;;;;      ENABLE_VIRTUAL_TERMINAL_PROCESSING（失败则退化为纯文本）。
;;;;   3. 输出被重定向到文件 / 管道时自动关闭颜色，避免写入转义垃圾。

(in-package :cl-user)

(defvar *ui-color-mode* :auto
  "颜色模式：:auto 自动检测；t 强制开启；nil 关闭。")

(defvar *ui-color-cache* :unknown
  "颜色可用性缓存；:unknown 表示尚未检测。")

(defparameter *ui-esc* (string (code-char 27))
  "ANSI 转义字符 ESC。")

(defun ui-reset-color-cache ()
  "清空颜色检测缓存（切换 /color 模式后调用）。"
  (setf *ui-color-cache* :unknown)
  t)

(defun ui-enable-vt ()
  "在 Windows 控制台上尝试开启 ANSI VT 处理；可用返回 T。"
  (when (fboundp 'win32-enable-vt-processing)
    (ignore-errors (funcall 'win32-enable-vt-processing))))

(defun ui-term-hint-p ()
  "终端环境变量是否暗示支持 ANSI 颜色。"
  (let ((term (uiop:getenv "TERM")))
    (and (or term
             (uiop:getenv "COLORTERM")
             (uiop:getenv "WT_SESSION")
             (uiop:getenv "ConEmuANSI"))
         (not (and term (string-equal term "dumb")))
         t)))

(defun ui-color-on-p ()
  "当前是否应输出 ANSI 颜色（结果缓存）。"
  (when (eq *ui-color-cache* :unknown)
    (setf *ui-color-cache*
          (cond
            ((eq *ui-color-mode* t) t)
            ((null *ui-color-mode*) nil)
            ((uiop:getenv "NO_COLOR") nil)
            ((uiop:getenv "MYAGENT_NO_COLOR") nil)
            ((uiop:os-windows-p)
             (or (and (ui-enable-vt) t)
                 (and (ui-term-hint-p) t)))
            (t t))))
  (eq *ui-color-cache* t))

;;; ── 基础着色 ────────────────────────────────────────────

(defun ui-colorize (style text)
  "按 ANSI 参数着色（style 如 \"1;36\"）；颜色关闭时原样返回。"
  (if (ui-color-on-p)
      (concatenate 'string *ui-esc* "[" style "m" text *ui-esc* "[0m")
      text))

(defun ui-bold (s) (ui-colorize "1" s))
(defun ui-dim (s) (ui-colorize "90" s))
(defun ui-gray (s) (ui-colorize "90" s))
(defun ui-red (s) (ui-colorize "31" s))
(defun ui-green (s) (ui-colorize "32" s))
(defun ui-yellow (s) (ui-colorize "33" s))
(defun ui-blue (s) (ui-colorize "34" s))
(defun ui-magenta (s) (ui-colorize "35" s))
(defun ui-cyan (s) (ui-colorize "36" s))

;;; ── 语义标签（替代 emoji 的唯一提示方案） ───────────────

(defun ui-tag (label style)
  "生成彩色方括号标签，例如 (ui-tag \"成功\" \"1;32\") → [成功]。"
  (ui-colorize style (format nil "[~A]" label)))

(defun ui-tag-ok (label) (ui-tag label "1;32"))
(defun ui-tag-err (label) (ui-tag label "1;31"))
(defun ui-tag-warn (label) (ui-tag label "1;33"))
(defun ui-tag-info (label) (ui-tag label "36"))
(defun ui-tag-key (label) (ui-tag label "1;34"))

(defun ui-rule (&optional (width 60) (ch #\─))
  "返回一条灰色分隔线。"
  (ui-dim (make-string width :initial-element ch)))

(defun ui-palette-preview ()
  "返回一行配色样例，便于 /color 命令验证终端是否支持颜色。"
  (format nil "~A ~A ~A ~A ~A"
          (ui-tag-ok "成功") (ui-tag-err "失败") (ui-tag-warn "警告")
          (ui-tag-info "提示") (ui-tag-key "配置")))
