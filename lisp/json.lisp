;;;; lisp/json.lisp
;;;; 纯 Common Lisp 零依赖 JSON 解析器与序列化器 (RFC 8259)
;;;; 支持 UTF-8、代理对 (Emoji)、Hash-Table 对象、列表数组。
;;;;
;;;; 数据映射约定：
;;;;   JSON Object  <-> Hash-Table (:test 'equal)
;;;;   JSON Array   <-> List (nil 表示空数组 []) 或 Vector
;;;;   JSON String  <-> String
;;;;   JSON Number  <-> Integer / Double-Float
;;;;   JSON true    <-> t 或 :true
;;;;   JSON false   <-> :false
;;;;   JSON null    <-> :null

(in-package :cl-user)

;;; ── 便捷构造函数与访问器 ──────────────────────────────

(defun jobj (&rest kvs)
  "快速构建 JSON 对象 (equal hash-table)。用法: (jobj \"role\" \"user\" \"content\" \"hi\")"
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash (if (symbolp k) (string-downcase (symbol-name k)) ( string k)) ht) v))
    ht))

(defun jget (obj key &optional default)
  "从 JSON 对象 (hash-table) 中读取字段。"
  (if (hash-table-p obj)
      (gethash key obj default)
      default))

(defun (setf jget) (val obj key)
  "设置 JSON 对象 (hash-table) 中的字段。"
  (setf (gethash key obj) val))

(defun jtrue-p (val)
  "判断 JSON 值是否为真（非 nil、非 :false、非 :null）。"
  (and val (not (eq val :false)) (not (eq val :null))))

;;; ── JSON 序列化 (Encode) ──────────────────────────────

(defun write-json-string (str stream)
  "将 Lisp 字符串转义并写入流。"
  (write-char #\" stream)
  (loop for ch across str
        for code = (char-code ch)
        do (case ch
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (otherwise
              (if (< code 32)
                  (format stream "\\u~4,'0X" code)
                  (write-char ch stream)))))
  (write-char #\" stream))

(defun write-json-value (val stream)
  "将 Lisp 值序列化为 JSON 写入 stream。"
  (cond
    ((or (eq val t) (eq val :true))
     (write-string "true" stream))
    ((eq val :false)
     (write-string "false" stream))
    ((eq val :null)
     (write-string "null" stream))
    ((null val)
     (write-string "[]" stream))
    ((stringp val)
     (write-json-string val stream))
    ((integerp val)
     (format stream "~D" val))
    ((realp val)
     (let ((*read-default-float-format* 'double-float))
       (format stream "~F" ( coerce val 'double-float))))
    ((symbolp val)
     (write-json-string (string-downcase (symbol-name val)) stream))
    ((hash-table-p val)
     (write-char #\{ stream)
     (let ((first t))
       (maphash (lambda (k v)
                  (unless first (write-char #\, stream))
                  (setf first nil)
                  (write-json-string (if (stringp k) k (princ-to-string k)) stream)
                  (write-char #\: stream)
                  (write-json-value v stream))
                val))
     (write-char #\} stream))
    ((listp val)
     (write-char #\[ stream)
     (loop for (item . rest) on val
           do (write-json-value item stream)
              (when rest (write-char #\, stream)))
     (write-char #\] stream))
    ((vectorp val)
     (write-char #\[ stream)
     (loop for i from 0 below (length val)
           do (when (> i 0) (write-char #\, stream))
              (write-json-value (aref val i) stream))
     (write-char #\] stream))
    (t
     (write-json-string (princ-to-string val) stream))))

(defun json-encode (val)
  "将 Lisp 数据结构编码为 JSON 字符串。"
  (with-output-to-string (s)
    (write-json-value val s)))

;;; ── JSON 解析 (Decode) ────────────────────────────────

(defun json-whitespace-p (ch)
  (and ch (member ch '(#\Space #\Tab #\Newline #\Return))))

(defun skip-json-whitespace (str pos len)
  (loop while (and (< pos len) (json-whitespace-p (char str pos)))
        do (incf pos))
  pos)

(defun parse-hex4 (str pos len)
  (when (> (+ pos 4) len)
    (error "JSON 字符串 \\u 转义不完整，位置 ~D" pos))
  (parse-integer str :start pos :end (+ pos 4) :radix 16))

(defun parse-json-string (str pos len)
  "从 pos (指向起始双引号之后) 解析 JSON 字符串，返回 (values string new-pos)。"
  (let ((out (make-array 32 :element-type 'character :fill-pointer 0 :adjustable t)))
    (loop
      (when (>= pos len)
        (error "JSON 字符串未闭合"))
      (let ((ch (char str pos)))
        (incf pos)
        (cond
          ((char= ch #\")
           (return (values (copy-seq out) pos)))
          ((char= ch #\\)
           (when (>= pos len)
             (error "JSON 转义序列未完成"))
           (let ((esc (char str pos)))
             (incf pos)
             (case esc
               (#\" (vector-push-extend #\" out))
               (#\\ (vector-push-extend #\\ out))
               (#\/ (vector-push-extend #\/ out))
               (#\b (vector-push-extend #\Backspace out))
               (#\f (vector-push-extend #\Page out))
               (#\n (vector-push-extend #\Newline out))
               (#\r (vector-push-extend #\Return out))
               (#\t (vector-push-extend #\Tab out))
               (#\u
                (let ((code1 (parse-hex4 str pos len)))
                  (incf pos 4)
                  ;; 处理 UTF-16 代理对 (Surrogate Pair: D800..DBFF + DC00..DFFF)
                  (if (and (<= #xD800 code1 #xDBFF)
                           (<= (+ pos 6) len)
                           (char= (char str pos) #\\)
                           (char= (char str (+ pos 1)) #\u))
                      (let ((code2 (parse-hex4 str (+ pos 2) len)))
                        (if (<= #xDC00 code2 #xDFFF)
                            (let ((full-code (+ #x10000
                                                (ash (- code1 #xD800) 10)
                                                (- code2 #xDC00))))
                              (incf pos 6)
                              (vector-push-extend (code-char full-code) out))
                            (vector-push-extend (code-char code1) out)))
                      (vector-push-extend (code-char code1) out))))
               (otherwise
                (vector-push-extend esc out)))))
          (t
           (vector-push-extend ch out)))))))

(defun parse-json-number (str pos len)
  "解析 JSON 数字，返回 (values number new-pos)。"
  (let ((start pos)
        (is-float nil))
    (when (and (< pos len) (char= (char str pos) #\-))
      (incf pos))
    (loop while (and (< pos len) (digit-char-p (char str pos)))
          do (incf pos))
    (when (and (< pos len) (char= (char str pos) #\.))
      (setf is-float t)
      (incf pos)
      (loop while (and (< pos len) (digit-char-p (char str pos)))
            do (incf pos)))
    (when (and (< pos len) (member (char str pos) '(#\e #\E)))
      (setf is-float t)
      (incf pos)
      (when (and (< pos len) (member (char str pos) '(#\+ #\-)))
        (incf pos))
      (loop while (and (< pos len) (digit-char-p (char str pos)))
            do (incf pos)))
    (let ((num-str (subseq str start pos)))
      (if is-float
          (let ((*read-default-float-format* 'double-float))
            (values (read-from-string num-str) pos))
          (values (parse-integer num-str) pos)))))

(defun parse-json-value (str pos len)
  "从 pos 解析任意 JSON 值，返回 (values val new-pos)。"
  (setf pos (skip-json-whitespace str pos len))
  (when (>= pos len)
    (error "JSON 意外结束"))
  (let ((ch (char str pos)))
    (cond
      ;; String
      ((char= ch #\")
       (parse-json-string str (1+ pos) len))
      ;; Object
      ((char= ch #\{)
       (let ((ht (make-hash-table :test 'equal)))
         (incf pos)
         (setf pos (skip-json-whitespace str pos len))
         (when (and (< pos len) (char= (char str pos) #\}))
           (return-from parse-json-value (values ht (1+ pos))))
         (loop
           (setf pos (skip-json-whitespace str pos len))
           (unless (and (< pos len) (char= (char str pos) #\"))
             (error "JSON 对象期望字符串键，位置 ~D" pos))
           (multiple-value-bind (key next-pos)
               (parse-json-string str (1+ pos) len)
             (setf pos (skip-json-whitespace str next-pos len))
             (unless (and (< pos len) (char= (char str pos) #\:))
               (error "JSON 对象期望 ':'，位置 ~D" pos))
             (multiple-value-bind (val val-pos)
                 (parse-json-value str (1+ pos) len)
               (setf (gethash key ht) val)
               (setf pos (skip-json-whitespace str val-pos len))
               (when (>= pos len)
                 (error "JSON 对象未闭合"))
               (let ((sep (char str pos)))
                 (incf pos)
                 (cond
                   ((char= sep #\}) (return (values ht pos)))
                   ((char= sep #\,))
                   (t (error "JSON 对象期望 ',' 或 '}'，实际为 ~C，位置 ~D" sep (1- pos))))))))))
      ;; Array
      ((char= ch #\[)
       (let ((items nil))
         (incf pos)
         (setf pos (skip-json-whitespace str pos len))
         (when (and (< pos len) (char= (char str pos) #\]))
           (return-from parse-json-value (values nil (1+ pos))))
         (loop
           (multiple-value-bind (val next-pos)
               (parse-json-value str pos len)
             (push val items)
             (setf pos (skip-json-whitespace str next-pos len))
             (when (>= pos len)
               (error "JSON 数组未闭合"))
             (let ((sep (char str pos)))
               (incf pos)
               (cond
                 ((char= sep #\]) (return (values (nreverse items) pos)))
                 ((char= sep #\,))
                 (t (error "JSON 数组期望 ',' 或 ']'，实际为 ~C，位置 ~D" sep (1- pos)))))))))
      ;; true
      ((and (<= (+ pos 4) len) (string= str "true" :start1 pos :end1 (+ pos 4)))
       (values t (+ pos 4)))
      ;; false
      ((and (<= (+ pos 5) len) (string= str "false" :start1 pos :end1 (+ pos 5)))
       (values :false (+ pos 5)))
      ;; null
      ((and (<= (+ pos 4) len) (string= str "null" :start1 pos :end1 (+ pos 4)))
       (values :null (+ pos 4)))
      ;; Number
      ((or (char= ch #\-) (digit-char-p ch))
       (parse-json-number str pos len))
      (t
       (error "非法 JSON 字符 '~C' 在位置 ~D" ch pos)))))

(defun json-decode (str)
  "将 JSON 字符串解析为 Lisp 数据结构。"
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return #\⭕ #\ufeff) str)))
    (when (zerop (length trimmed))
      (error "空 JSON 字符串"))
    (values (parse-json-value trimmed 0 (length trimmed)))))
