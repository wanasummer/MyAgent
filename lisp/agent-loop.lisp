;;;; lisp/agent-loop.lisp
;;;; 核心 Agent 循环 (ReAct Loop) — Common Lisp 原生热迭代与 Prompt Cache 优化版

(in-package :cl-user)

(defparameter *max-turns* 40
  "单次对话最大 ReAct 推理轮数。")

(defparameter *max-empty-answer-retries* 1
  "模型返回「无文本内容」时，自动请求其补充回答的最大次数（只重试 1 次，节省轮数）。")

(defparameter *auto-reload-before-turn* nil
  "是否在每轮推理前自动扫描并热重载磁盘上被修改的 .lisp 文件。默认 nil：避免任务进行中因外部改动/自动回滚而被打断。需要时设 t，或用 reload_lisp 手动重载。")

(defparameter *system-prompt*
  "你是一个基于原生 Common Lisp (SBCL) 构建的本地文件管理与自我演化 Agent。
你可以使用提供的工具来操控本机文件系统，并利用 Lisp 的动态热重载与求值能力在对话中直接迭代自身的核心功能。

## 🔥 Lisp 实时自我迭代机制（免重启）

你的全部核心代码运行在单个常驻 SBCL 进程镜像中，源码位于项目的 `lisp/` 目录下：
- `lisp/reload-engine.lisp` — 安全热重载引擎（快照 / 自动回滚 / 错误回传）
- `lisp/json.lisp`       — 纯 Common Lisp JSON 解析与序列化器
- `lisp/config.lisp`     — `.env` 与多提供商 LLM 配置解析
- `lisp/file-utils.lisp` — 文件与目录读写底层实现
- `lisp/llm-client.lisp` — Anthropic / OpenAI / ThirdParty 多提供商客户端
- `lisp/tools.lisp`      — 动态工具注册表 (`*tool-registry*`) 与工具实现
- `lisp/agent-loop.lisp` — 核心 ReAct Agent 循环 (`run-agent`)
- `lisp/cli.lisp`        — 控制台交互式 CLI REPL

当用户要求你新增功能、修改核心逻辑或新增工具时：
1. **持久化修改并自动热重载**：使用 `write_file` 修改 `lisp/*.lisp` 中的代码。`write_file` 写入 `.lisp` 文件后会自动调用 `(hot-reload-lisp-file ...)` 将新定义即时编译加载进当前内存镜像！
2. **内存即时求值 (`eval_lisp`)**：你也可以直接调用 `eval_lisp` 工具执行 `(defun ...)` 或 `(register-tool ...)`。新注册或修改的工具在**下一轮推理 (Turn) 中即可立即调用**，完全无需退出或执行 `npm run dev` / 构建脚本！
3. **失败自动回滚（重要）**：热重载失败**不会中断任务**。系统会自动把磁盘文件与内存定义回滚到「上一个可用版本」，并把编译错误返回给你（在 write_file 的返回值或 <system-reminder> 里）。看到「热重载失败」时，务必阅读错误、修复代码后重新写入；在重载成功前，不要假设改动已生效。

## 你的工作模式：ReAct (Reasoning + Acting)

1. **思考 (Thought)**：分析用户意图，判断是否需要查看目录/文件或执行 Lisp 热更新。
2. **行动 (Action)**：调用合适的工具（文件工具、`eval_lisp`、`reload_lisp`）。
3. **观察 (Observation)**：分析工具返回结果。
4. **回答 (Answer)**：信息足够或操作完成后，用中文给出清晰完整的最终答案（以 ✅ 开头）。

## 行为准则

- **先看后动**：操作文件前先用 `list_directory` 或 `read_file` 了解情况。
- **路径使用**：支持绝对路径、相对路径和 `~`（自动展开为用户主目录）。
- **安全第一**：执行 `delete_path` 前务必确认用户意图。
- **中文交流**：始终用清晰简洁的中文与用户沟通。
- **禁止空回答**：每轮结束若不再调用工具，必须输出非空的最终文本答案。"
  "静态系统提示词（保持前缀一致以命中 Anthropic Prompt Cache）。")

;;; ── 动态环境上下文 (<system-reminder>) ───────────────

(defun build-environment-context ()
  "构建动态环境上下文，注入到用户消息中以保护 System Prompt 缓存。"
  (let* ((home-dir (get-user-home-dir))
         (desktop-dir (format nil "~A/Desktop" home-dir))
         (project-dir (resolve-path "."))
         (today (current-date-string)))
    (format nil "<system-reminder>~%## 当前环境~%- 今天的日期：~A~%- 运行时：SBCL ~A (Common Lisp)~%- 你的工作目录（项目目录）：`~A`~%- 核心 Lisp 源码目录：`~A/lisp`~%- 用户主目录：`~A`~%- 用户桌面：`~A`~%- 已注册工具列表：~{~A~^, ~}~%</system-reminder>"
            today
            (lisp-implementation-version)
            project-dir
            project-dir
            home-dir
            desktop-dir
            *tool-names-order*)))

;;; ── 日志参数截断格式化 ───────────────────────────────

(defun format-args-for-log (args-ht)
  "格式化工具参数用于日志输出，对超长字符串截断避免刷屏。"
  (if (not (hash-table-p args-ht))
      (princ-to-string args-ht)
      (let ((display (jobj))
            (max-len 120))
        (maphash (lambda (k v)
                   (if (and (stringp v) (> (length v) max-len))
                       (let* ((lines (1+ (count #\Newline v)))
                              (sub (substitute #\↵ #\Newline (subseq v 0 max-len))))
                         (setf (jget display k)
                               (format nil "~A… (共 ~D 字符, ~D 行)" sub (length v) lines)))
                       (setf (jget display k) v)))
                 args-ht)
        (json-encode display))))

;;; ── 消息 content 归一化与空回答诊断 ─────────────────

(defun block-type (block)
  "安全获取消息块的 type 字段。非 hash-table 或缺失时返回 nil。"
  (when (hash-table-p block)
    (let ((ty (jget block "type")))
      (if (stringp ty) ty nil))))

(defun content-as-blocks (content)
  "把 assistant 的 content 规范化为 block 列表。
兼容 nil / 字符串 / vector / 列表 四种形态，避免因端点返回 string 导致「回答 0 字符」。"
  (cond
    ((null content) nil)
    ((stringp content)
     (if (> (length content) 0)
         (list (jobj "type" "text" "text" content))
         nil))
    ((vectorp content) (coerce content 'list))
    ((listp content)
     (mapcar (lambda (c)
               (if (stringp c)
                   (jobj "type" "text" "text" c)
                   c))
             content))
    (t nil)))

(defun collect-answer-text (content)
  "拼接所有 text 块（忽略 thinking / tool_use 等其它块），返回去除首尾空白的文本。"
  (let ((parts nil))
    (dolist (b (content-as-blocks content))
      (when (and (hash-table-p b)
                 (equal (block-type b) "text")
                 (stringp (jget b "text")))
        (push (jget b "text") parts)))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (format nil "~{~A~^~%~}" (nreverse parts)))))

(defun describe-content-blocks (content)
  "生成 content block 类型摘要，用于诊断「空回答」。"
  (let ((types (mapcar (lambda (b) (or (block-type b) "unknown"))
                       (content-as-blocks content))))
    (if types
        (format nil "~{~A~^,~}" types)
        "空")))

(defun make-continue-nudge (stop-reason)
  "构造一条「请补充文本回答」的用户消息，用于空回答时自动追问。"
  (let ((text (if (member stop-reason '("max_tokens" "length") :test #'string=)
                  "你上一条回复因为输出长度上限被截断，并且没有产生任何文本内容。请直接输出最终的中文文本答案（除非确实必须，否则不要再调用工具）。"
                  "你上一条回复没有任何文本内容（既没有文本，也没有有效的工具调用）。请直接用中文文本回答用户的问题或说明当前进展，禁止返回空回复。")))
    (jobj "role" "user"
          "content" (list (jobj "type" "text" "text" text)))))

;;; ── 热重载错误的记录与注入 ───────────────────────────

(defun safe-check-and-hot-reload ()
  "永不抛错的热重载检查（热重载引擎缺失或异常时也不影响 Agent 任务）。"
  (when (fboundp 'check-and-hot-reload-modified-files)
    (handler-case (funcall 'check-and-hot-reload-modified-files)
      (serious-condition (e)
        (format *error-output* "  ⚠️ 热重载检查异常（已忽略）: ~A~%" e))))
  nil)

(defun reload-error-note ()
  "取出待注入的热重载错误并组装为系统提示；无错误返回 nil。"
  (when (fboundp 'drain-lisp-reload-errors)
    (let ((errs (ignore-errors (funcall 'drain-lisp-reload-errors))))
      (when errs
        (format nil "<system-reminder>~%## 🔁 Lisp 热重载失败（已自动回滚，任务继续）~%~{~A~%~}~%以上文件已被自动回滚到「上一个可用版本」，工具与核心函数仍在正常工作。请阅读错误、修复源码，然后用 write_file 重新写入。~%</system-reminder>"
                errs)))))

(defun tool-result-block-p (block)
  (and (hash-table-p block) (equal (block-type block) "tool_result")))

(defun inject-note-into-message-flow (messages note)
  "把 note 注入消息流，尽量不破坏 tool_use / tool_result 配对结构。
优先追加到最后一条 tool_result 的 content 里；否则追加为最后一条 user 消息的文本块，
或新增一条 user 消息。返回新的消息列表（不修改原消息对象）。"
  (if (null messages)
      (list (jobj "role" "user" "content" (list (jobj "type" "text" "text" note))))
      (let* ((last (car (last messages)))
             (role (and (hash-table-p last) (jget last "role")))
             (content (and (hash-table-p last) (jget last "content")))
             (tr-blocks (and (listp content)
                             (remove-if-not #'tool-result-block-p content)))
             (new-last
               (cond
                 (tr-blocks
                  (let* ((target (car (last tr-blocks)))
                         (old (jget target "content"))
                         (old-text (if (stringp old)
                                       old
                                       (or (ignore-errors (json-encode old)) "")))
                         (merged (format nil "~A~%~%~A" old-text note))
                         (replaced (jobj "type" "tool_result"
                                         "tool_use_id" (jget target "tool_use_id")
                                         "content" merged)))
                    (when (jget target "is_error")
                      (setf (jget replaced "is_error") (jget target "is_error")))
                    (jobj "role" role
                          "content" (mapcar (lambda (b)
                                              (if (eq b target) replaced b))
                                            content))))
                 ((equal role "user")
                  (jobj "role" role
                        "content" (list (jobj "type" "text"
                                              "text" (if (stringp content)
                                                         content
                                                         (format nil "~A" content)))
                                        (jobj "type" "text" "text" note))))
                 (t
                  (jobj "role" "user"
                        "content" (list (jobj "type" "text" "text" note)))))))
        (append (butlast messages) (list new-last)))))

;;; ── 修复孤立的 tool_use 配对 ─────────────────────────

(defun extract-tool-use-ids (msg)
  "提取 assistant 消息中的所有 tool_use ID。"
  (let ((ids nil)
        (content (and (hash-table-p msg) (jget msg "content"))))
    (when (listp content)
      (dolist (b content)
        (when (and (hash-table-p b)
                   (equal (block-type b) "tool_use")
                   (jget b "id"))
          (push (jget b "id") ids))))
    (nreverse ids)))

(defun extract-tool-result-ids (msg)
  "提取 user 消息中的所有 tool_result ID 集合。"
  (let ((ht (make-hash-table :test 'equal))
        (content (and (hash-table-p msg) (jget msg "content"))))
    (when (listp content)
      (dolist (b content)
        (when (and (hash-table-p b)
                   (equal (block-type b) "tool_result")
                   (jget b "tool_use_id"))
          (setf (gethash (jget b "tool_use_id") ht) t))))
    ht))

(defun fix-missing-tool-results (messages)
  "扫描并修复缺失配对的 tool_result，返回修复后的新消息列表。"
  (let ((out nil)
        (rest messages))
    (loop while rest
          for msg = (pop rest)
          for next-msg = (first rest)
          do (push msg out)
             (when (equal (jget msg "role") "assistant")
               (let ((use-ids (extract-tool-use-ids msg)))
                 (when use-ids
                   (let* ((has-next-user (and next-msg (equal (jget next-msg "role") "user")))
                          (res-ids (if has-next-user (extract-tool-result-ids next-msg) (make-hash-table :test 'equal)))
                          (missing (remove-if (lambda (id) (gethash id res-ids)) use-ids)))
                     (when missing
                       (let ((synthetic (mapcar (lambda (id)
                                                  (jobj "type" "tool_result"
                                                        "tool_use_id" id
                                                        "content" "⚠️ 此工具调用未完成（会话中断/恢复）。请忽略并继续。"))
                                                missing)))
                         (format t "  🔧 修复了 ~D 个缺失的 tool_result~%" (length missing))
                         (push (jobj "role" "user" "content" synthetic) out))))))))
    (nreverse out)))

;;; ── 工具执行 ─────────────────────────────────────────

(defun execute-tool-use-block (tool-use)
  "执行单个 tool_use 块，返回对应的 tool_result 块。任何异常都被捕获为可读错误结果。"
  (let* ((t-id (or (jget tool-use "id") (format nil "toolu_~D" (get-universal-time))))
         (t-name (jget tool-use "name"))
         (t-input (let ((in (jget tool-use "input")))
                    (if (hash-table-p in) in (jobj)))))
    (format t "  🔧 调用工具: ~A(~A)~%" t-name (format-args-for-log t-input))
    (finish-output)
    (handler-case
        ;; 通过符号 funcall 调用 execute-tool，确保热更新后立即走新逻辑
        (let* ((res (funcall 'execute-tool t-name t-input))
               (res-str (if (stringp res) res (json-encode res))))
          (jobj "type" "tool_result"
                "tool_use_id" t-id
                "content" res-str))
      (error (e)
        (jobj "type" "tool_result"
              "tool_use_id" t-id
              "content" (format nil "❌ 工具执行失败: ~A" e))))))

;;; ── Agent 主循环 ─────────────────────────────────────

(defun run-agent (user-input &optional history)
  "执行一次完整的 ReAct Agent 对话循环。
返回 plist: (:answer string :history list :input-tokens int :output-tokens int)"
  ;; 🔥 每次对话开始前检查是否有外部编辑过的 .lisp 文件，自动热重载
  (when *auto-reload-before-turn* (safe-check-and-hot-reload))

  (let* ((env-ctx (build-environment-context))
         (enriched-input (format nil "~A~%~%---~%~%~A" env-ctx user-input))
         (messages (fix-missing-tool-results
                    (append (copy-list history)
                            (list (jobj "role" "user" "content" enriched-input)))))
         (turns 0)
         (empty-retries 0)
         (total-in-tokens 0)
         (total-out-tokens 0))

    (loop while (< turns *max-turns*)
          do (incf turns)
             ;; 🔥 每轮推理前检查是否有热重载更新，并动态拉取最新工具表！
             (when *auto-reload-before-turn* (safe-check-and-hot-reload))

             ;; 🔁 若有热重载失败（自动回滚已完成），把错误注入给 LLM 后继续
             (let ((note (and *auto-reload-before-turn* (reload-error-note))))
               (when note
                 (setf messages (inject-note-into-message-flow messages note))))

             (let* ((all-tools (get-all-tool-definitions))
                    (response (chat-with-tools
                               :system *system-prompt*
                               :messages messages
                               :tools all-tools))
                    (usage (jget response "usage"))
                    (in-tok (if (hash-table-p usage) (or (jget usage "input_tokens") 0) 0))
                    (out-tok (if (hash-table-p usage) (or (jget usage "output_tokens") 0) 0))
                    (stop-reason (let ((sr (jget response "stop_reason")))
                                   (if (stringp sr) sr "end_turn")))
                    (content (content-as-blocks (jget response "content")))
                    (tool-uses (remove-if-not
                                (lambda (b) (equal (block-type b) "tool_use"))
                                content)))

               (incf total-in-tokens in-tok)
               (incf total-out-tokens out-tok)

               (setf messages (append messages (list (jobj "role" "assistant" "content" content))))

               (format t "  🔄 Turn ~D | stop_reason=~A | tools=~D | blocks=[~A] | tokens: +~D in / +~D out~%"
                       turns stop-reason (length tool-uses)
                       (describe-content-blocks content) in-tok out-tok)
               (finish-output)

               (cond
                 ;; ① 存在 tool_use → 无论 stop_reason 是什么都执行，绝不静默丢弃工具调用
                 (tool-uses
                  (when (and (not (equal stop-reason "tool_use"))
                             (not (equal stop-reason "max_tokens")))
                    (format t "  ⚠️ stop_reason=~A 但响应含 ~D 个 tool_use，仍按工具调用处理。~%"
                            stop-reason (length tool-uses))
                    (finish-output))
                  (let ((tool-results nil))
                    (dolist (tc tool-uses)
                      (push (execute-tool-use-block tc) tool-results))
                    (setf messages
                          (append messages
                                  (list (jobj "role" "user"
                                              "content" (nreverse tool-results)))))))

                 ;; ② 无工具调用 → 提取文本答案
                 (t
                  (let ((answer (collect-answer-text content)))
                    (cond
                      ;; 正常回答
                      ((> (length answer) 0)
                       (let ((total-tok (+ total-in-tokens total-out-tokens)))
                         (format t "  ✅ 回答 (~D 字符) | 共 ~D tokens (in: ~D / out: ~D)~%"
                                 (length answer) total-tok total-in-tokens total-out-tokens)
                         (finish-output)
                         (return-from run-agent
                           (list :answer answer
                                 :history messages
                                 :input-tokens total-in-tokens
                                 :output-tokens total-out-tokens))))

                      ;; 空回答 → 自动追问模型补充（有限次）
                      ((< empty-retries *max-empty-answer-retries*)
                       (incf empty-retries)
                       (format t "  ⚠️ 本轮回答为空（stop_reason=~A, blocks=[~A]），自动请求模型补充文本 (~D/~D)~%"
                               stop-reason (describe-content-blocks content)
                               empty-retries *max-empty-answer-retries*)
                       (finish-output)
                       (setf messages (append messages (list (make-continue-nudge stop-reason)))))

                      ;; 仍为空 → 返回可读诊断，避免把空串当最终答案
                      (t
                       (let ((diagnostic
                               (format nil "⚠️ 模型在本轮未返回任何文本内容（stop_reason=~A，content blocks=[~A]）。可能原因：输出被截断、模型只返回了思考/工具块、或服务端响应异常。建议重试本次提问；若持续出现，可用 /reload 检查配置或 /model 重新确认 Key。"
                                       stop-reason (describe-content-blocks content))))
                         (format t "  ⚠️ ~A~%" diagnostic)
                         (finish-output)
                         (return-from run-agent
                           (list :answer diagnostic
                                 :history messages
                                 :input-tokens total-in-tokens
                                 :output-tokens total-out-tokens))))))))))

    ;; 超过最大轮数
    (let ((last-text (collect-answer-text
                      (let ((last-msg (car (last messages))))
                        (and (hash-table-p last-msg) (jget last-msg "content"))))))
      (list :answer (if (> (length last-text) 0)
                        last-text
                        "⚠️ 达到最大轮数限制，已停止思考。")
            :history messages
            :input-tokens total-in-tokens
            :output-tokens total-out-tokens))))
