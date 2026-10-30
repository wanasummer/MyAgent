;;;; lisp/cancel.lisp
;;;; 对话中断控制：Agent 执行期间按 ESC 立即取消当前任务，但保留已产生的上下文调用链。
;;;;
;;;; 设计要点：
;;;; 1) LLM 请求放到后台线程执行，主线程每 50ms 轮询一次控制台输入队列；
;;;;    检测到 ESC 就把本次任务标记为「已中断」，丢弃后台请求的返回结果。
;;;; 2) 后台线程不强行终止（避免在 curl / 文件 IO 中途破坏进程状态），
;;;;    它会在请求自然结束后安静退出，结果直接丢弃。
;;;; 3) 取消时不会清空 *session-history*，已完成轮次的 assistant / tool_result
;;;;    全部保留，下一次提问直接接着这条调用链继续。

(in-package :cl-user)

(defvar *agent-busy* nil
  "run-agent 是否正在执行中（由 run-agent 动态绑定为 T）。")

(defvar *agent-cancel-requested* nil
  "本次 Agent 任务是否已被用户按 ESC 中断。")

(defparameter *cancel-poll-interval* 0.05
  "等待模型响应期间检测 ESC 的轮询间隔（秒）。")

(defun reset-cancel-state ()
  "开始一次新的 Agent 任务：清除上一次的中断标记。"
  (setf *agent-cancel-requested* nil)
  nil)

(defun agent-cancel-requested-p ()
  "本次 Agent 任务是否已被用户中断。"
  (and *agent-cancel-requested* t))

(defun interactive-cancel-available-p ()
  "当前是否具备「按 ESC 中断」的交互条件（Windows 真控制台 + 裸输入模式）。"
  (and (fboundp 'cli-escape-watchable-p)
       (ignore-errors (funcall 'cli-escape-watchable-p))
       t))

(defun poll-user-cancel ()
  "非阻塞检测用户是否按下了 ESC。返回 T 表示已请求中断。"
  (when (and *agent-busy* (not *agent-cancel-requested*))
    (when (and (interactive-cancel-available-p)
               (ignore-errors (funcall 'cli-escape-key-pending-p)))
      (setf *agent-cancel-requested* t)
      ;; 消费掉输入队列里的 ESC，避免它残留到下一次输入时把用户刚打的字清空
      (ignore-errors (funcall 'cli-consume-escape-presses))
      t)))

#+sb-thread
(defun start-worker-thread (fn name)
  "在后台线程执行 FN（线程创建失败时返回 NIL）。"
  (handler-case
      (sb-thread:make-thread fn :name name)
    (error () nil)))

#-sb-thread
(defun start-worker-thread (fn name)
  (declare (ignore fn name))
  nil)

(defun call-with-cancel-polling (thunk)
  "在后台线程执行 THUNK，同时在主线程轮询 ESC。
返回 (values 结果 :done) 或 (values nil :cancelled)。
非交互场景（无控制台 / 无线程支持）直接同步执行，行为与原来完全一致。
取消后后台请求不会被强行杀死（避免破坏 curl / GC 状态），其返回结果直接丢弃。"
  (if (not (interactive-cancel-available-p))
      (values (funcall thunk) :done)
      (let ((done nil)
            (value nil)
            (failure nil)
            (cancelled nil))
        (let ((thread
                (start-worker-thread
                 (lambda ()
                   (handler-case
                       (setf value (funcall thunk))
                     (serious-condition (e) (setf failure e)))
                   (setf done t)
                   nil)
                 "myagent-llm-request")))
          (if (null thread)
              ;; 线程创建失败：退化为同步执行，保证功能不中断
              (values (funcall thunk) :done)
              (progn
                (loop
                  (when done (return))
                  (when (poll-user-cancel)
                    (setf cancelled t)
                    (return))
                  (sleep *cancel-poll-interval*))
                (cond
                  (cancelled
                   ;; 后台线程会在请求自然结束后自行退出，这里不 join、不强杀
                   (values nil :cancelled))
                  (failure
                   (error failure))
                  (t
                   #+sb-thread (ignore-errors (sb-thread:join-thread thread :timeout 1))
                   (values value :done)))))))))
