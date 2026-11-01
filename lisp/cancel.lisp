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

(declaim (special *supervisor-enabled*
                  *supervisor-soft-stall-seconds*
                  *supervisor-sample-interval*
                  *supervisor-sample-count*
                  *supervisor-stall-count*))

(defvar *agent-busy* nil
  "run-agent 是否正在执行中（由 run-agent 动态绑定为 T）。")

(defvar *agent-cancel-requested* nil
  "本次 Agent 任务是否已被用户按 ESC 中断。")

(defparameter *cancel-poll-interval* 0.05
  "等待模型响应与工具执行期间检测 ESC 的轮询间隔（秒）。")

(defparameter *eval-lisp-timeout-seconds* 15
  "eval_lisp 工具单次求值的最大超时秒数（防止死循环或阻塞读控制台导致永久卡死）。")

(defparameter *default-tool-timeout-seconds* 30
  "普通工具单次执行的最大超时秒数。")

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
      ;; 若当前有正在进行的流式 curl 子进程，立即终止使其退出阻塞的 read-line
      (when (fboundp 'abort-active-llm-stream)
        (ignore-errors (funcall 'abort-active-llm-stream)))
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

#+sb-thread
(defun stop-worker-thread (thread)
  "安全停止卡死的工作线程：先注入 error 让 unwind-protect 清理栈正常执行，超时未退再强制终止。"
  (when (and thread (ignore-errors (sb-thread:thread-alive-p thread)))
    (ignore-errors
      (sb-thread:interrupt-thread
       thread
       (lambda () (error "任务已被中断或执行超时"))))
    (dotimes (i 10)
      (declare (ignore i))
      (unless (ignore-errors (sb-thread:thread-alive-p thread))
        (return))
      (sleep 0.01))
    (when (ignore-errors (sb-thread:thread-alive-p thread))
      (ignore-errors (sb-thread:terminate-thread thread))))
  nil)

#-sb-thread
(defun stop-worker-thread (thread)
  (declare (ignore thread))
  nil)

(defun call-with-cancel-polling (thunk)
  "在后台线程执行 THUNK，同时在主线程轮询 ESC。
返回 (values 结果 :done) 或 (values nil :cancelled)。
非交互场景（无控制台 / 无线程支持）直接同步执行，行为与原来完全一致。"
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
                  (when (or (agent-cancel-requested-p) (poll-user-cancel))
                    (setf cancelled t)
                    (when (fboundp 'abort-active-llm-stream)
                      (ignore-errors (funcall 'abort-active-llm-stream)))
                    (return))
                  (sleep *cancel-poll-interval*))
                (cond
                  (cancelled
                   (values nil :cancelled))
                  (failure
                   (error failure))
                  (t
                   #+sb-thread (ignore-errors (sb-thread:join-thread thread :timeout 1))
                   (values value :done)))))))))

(defun call-tool-with-cancel-and-timeout (thunk &key (timeout *default-tool-timeout-seconds*)
                                                     (tool-name "tool")
                                                     (args-summary ""))
  "在后台工作线程执行工具 THUNK，主线程同时运行：
1) ESC 实时中断轮询；
2) 旁路督导子 Agent (Supervisor Watchdog)：监测进展心跳 + SBCL 实时调用栈采样，
   动态做出 :extend（顺延等待）、:abort-tool（中断死循环工具）或 :rollback-code（程序化回滚代码）决策。
返回：
  (values 结果 :done nil)
  (values nil :cancelled nil)
  (values nil :timeout 诊断详情)
  (values nil :rollback 诊断详情)"
  (let* ((done nil)
         (value nil)
         (failure nil)
         (status :done)
         (diagnostic nil)
         (start-time (get-internal-real-time))
         (last-progress-time start-time)
         (last-sample-time 0)
         (last-sig (if (fboundp 'current-worker-progress-signature)
                       (funcall 'current-worker-progress-signature)
                       0))
         (samples nil)
         (extensions-used 0)
         (sup-enabled (and (boundp '*supervisor-enabled*)
                           (symbol-value '*supervisor-enabled*)
                           (fboundp 'sample-worker-backtrace)
                           (fboundp 'supervisor-decide-action))))
    (labels ((sec-since (t0)
               (/ (- (get-internal-real-time) t0)
                  (float internal-time-units-per-second))))
      (let ((thread
              (start-worker-thread
               (lambda ()
                 (handler-case
                     (setf value (funcall thunk))
                   (serious-condition (e) (setf failure e)))
                 (setf done t)
                 nil)
               "myagent-tool-worker")))
        (if (null thread)
            (values (funcall thunk) :done nil)
            (progn
              (loop
                (when done (return))
                ;; 1) 用户按 ESC 立即中断
                (when (or (agent-cancel-requested-p) (poll-user-cancel))
                  (setf status :cancelled)
                  (stop-worker-thread thread)
                  (return))

                (cond
                  ;; 2) 启用旁路督导子 Agent：进展心跳 + 栈采样 + 智能决策
                  (sup-enabled
                   (let ((cur-sig (funcall 'current-worker-progress-signature)))
                     (if (/= cur-sig last-sig)
                         ;; 有新进展（输出增长或文件操作推进）→ 重置停滞计时与采样
                         (setf last-sig cur-sig
                               last-progress-time (get-internal-real-time)
                               samples nil)
                         ;; 无进展时间超过软阈值 → 周期性采集 SBCL 调用栈
                         (let ((stall-sec (sec-since last-progress-time))
                               (soft-limit (or (and (boundp '*supervisor-soft-stall-seconds*)
                                                    *supervisor-soft-stall-seconds*)
                                               6.0))
                               (sample-int (or (and (boundp '*supervisor-sample-interval*)
                                                    *supervisor-sample-interval*)
                                               2.0))
                               (need-samples (or (and (boundp '*supervisor-sample-count*)
                                                      *supervisor-sample-count*)
                                                 3)))
                           (when (and (>= stall-sec soft-limit)
                                      (or (zerop last-sample-time)
                                          (>= (sec-since last-sample-time) sample-int)))
                             (setf last-sample-time (get-internal-real-time))
                             (let ((bt (funcall 'sample-worker-backtrace thread)))
                               (push bt samples))
                             (when (>= (length samples) need-samples)
                               (let ((ordered-samples (nreverse (copy-list samples)))
                                     (total-sec (sec-since start-time)))
                                 (multiple-value-bind (decision reason)
                                     (funcall 'supervisor-decide-action
                                              tool-name args-summary total-sec
                                              ordered-samples extensions-used)
                                   (cond
                                     ((eq decision :extend)
                                      (incf extensions-used)
                                      (setf samples nil
                                            last-progress-time (get-internal-real-time))
                                      (format t "    ~A 观察窗口顺延 (#~D): ~A~%"
                                              (if (fboundp 'ui-dim) (funcall 'ui-dim "[督导]") "[督导]")
                                              extensions-used reason)
                                      (finish-output))
                                     ((eq decision :rollback-code)
                                      (when (boundp '*supervisor-stall-count*)
                                        (incf *supervisor-stall-count*))
                                      (stop-worker-thread thread)
                                      (let ((rolled (and (fboundp 'rollback-unverified-lisp-files)
                                                         (funcall 'rollback-unverified-lisp-files reason))))
                                        (setf status :rollback
                                              diagnostic (format nil "~A~%已自动回滚未验证文件: ~{~A~^, ~}~%卡死位置调用栈:~%~A"
                                                                 reason (or rolled '("(无)"))
                                                                 (funcall 'format-backtrace-samples ordered-samples))))
                                      (return))
                                     (t
                                      (when (boundp '*supervisor-stall-count*)
                                        (incf *supervisor-stall-count*))
                                      (stop-worker-thread thread)
                                      (setf status :timeout
                                            diagnostic (format nil "~A~%卡死位置实时 SBCL 调用栈:~%~A"
                                                               reason
                                                               (funcall 'format-backtrace-samples ordered-samples)))
                                      (return)))))))))))

                  ;; 3) 未启用督导器时的传统固定超时兜底
                  ((and timeout (> (sec-since start-time) timeout))
                   (setf status :timeout
                         diagnostic (format nil "执行超过固定超时阈值 ~D 秒" timeout))
                   (stop-worker-thread thread)
                   (return)))

                (sleep *cancel-poll-interval*))

              (cond
                ((eq status :cancelled)
                 (values nil :cancelled nil))
                ((eq status :rollback)
                 (values nil :rollback diagnostic))
                ((eq status :timeout)
                 (values nil :timeout diagnostic))
                (failure
                 (error failure))
                (t
                 #+sb-thread (ignore-errors (sb-thread:join-thread thread :timeout 1))
                 (values value :done nil)))))))))
