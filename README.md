# λ MyAgent (Common Lisp Edition)

基于原生 **Common Lisp (SBCL)** 构建的本地文件管理与实时自我演化 Agent。

零第三方库依赖（仅依赖 SBCL 与系统 `curl`），利用 Lisp 的 **同像性 (Homoiconicity)** 与运行时热编译（`load` / `eval`），实现**在对话过程中直接修改或扩展核心功能，即刻生效，无需重启进程或执行任何构建脚本**。

---

## ✨ 主要特性

- **开箱即用**：项目内置 SBCL 运行时（`bin/`），无需安装任何依赖
- **免重启自迭代**：修改 `.lisp` 即热重载；失败自动回滚到上一个可用版本，任务不中断
- **终端 Markdown 渲染**：标题 / 列表 / 代码块 / **表格等宽对齐**（中文按 2 列宽）/ 长单元格自动折行
- **CMD 友好**：emoji、键帽数字（`5️⃣`）自动降级为纯文本，避免乱码
- **持久化记忆**：Markdown 文件存储，跨会话保留，目录随项目走
- **跨平台**：Windows（`start.bat`）/ Linux、macOS（`start.sh`）

---

## 📂 项目结构

```text
├── run.lisp              # SBCL 启动与模块引导入口
├── start.bat             # Windows 启动脚本（优先使用 bin/ 内置运行时）
├── start.sh              # Linux / macOS 启动脚本
├── .env.example          # 环境变量示例
├── bin/                  # 内置 SBCL 运行时（sbcl(.exe) + sbcl.core + contrib/）
│   └── README.md         # 运行时获取方式与许可说明
├── memory/               # 持久化记忆（默认不纳入版本控制）
└── lisp/
    ├── json.lisp         # 纯 Common Lisp RFC 8259 JSON 解析与序列化
    ├── config.lisp       # .env / 配置加载与 DeepSeek 配置解析
    ├── file-utils.lisp   # 文件读写、搜索、移动、删除 + 路径工具
    ├── markdown.lisp     # 终端 Markdown 渲染（表格对齐 / emoji 降级）
    ├── llm-client.lisp   # DeepSeek LLM 客户端（Anthropic Messages 兼容）
    ├── reload-engine.lisp# 安全热重载引擎（快照 / 回滚 / 错误回传）
    ├── tools.lisp        # 动态工具注册表 + 内置工具实现
    ├── agent-loop.lisp   # ReAct Agent 主循环
    └── cli.lisp          # 控制台交互式 REPL
```

---

## 🚀 快速开始

### 方式 A：使用内置运行时（推荐，零安装）

```powershell
.\start.bat            # Windows
```

```bash
chmod +x start.sh && ./start.sh   # Linux / macOS（需把对应平台运行时放入 bin/）
```

启动脚本会**优先使用 `bin/` 里的 SBCL**，并自动设置 `SBCL_HOME`。

> `bin/` 默认不随仓库分发（约 48 MB 二进制）。获取方式见 [`bin/README.md`](bin/README.md)：
> 把本机 SBCL 安装目录下的 `sbcl(.exe)`、`sbcl.core`、`contrib/` 复制进去即可。

### 方式 B：使用系统已安装的 SBCL

```bash
# macOS
brew install sbcl
# Debian/Ubuntu
sudo apt install sbcl
# Windows
scoop install sbcl    # 或 choco install sbcl
```

然后启动（脚本会自动探测 PATH 与常见安装位置）：

```powershell
.\start.bat
```

```bash
./start.sh
```

也可以直接用 SBCL 启动：

```bash
sbcl --noinform --load run.lisp
```

### 配置 DeepSeek API Key

进入控制台后：

- `/model` —— 交互式向导，填入 API Key（默认模型 `deepseek-flash`），自动保存
- `/model sk-xxxx` —— 单行快捷配置

Key 保存在 `~/.myagent/config`（**不在项目目录内，不会被提交**）。

---

## 🗂 数据与配置位置

| 内容 | 默认位置 | 是否入库 | 覆盖用环境变量 |
|---|---|---|---|
| 持久化记忆 | `<项目根>/memory/*.md` | ❌（`.gitignore` 已排除） | `MYAGENT_MEMORY_DIR` |
| API Key 配置 | `~/.myagent/config` | ❌ | `MYAGENT_CONFIG` |
| 本地环境变量 | `<项目根>/.env` | ❌ | — |
| 内置运行时 | `<项目根>/bin/` | ❌（二进制） | `MYAGENT_SBCL` |
| 项目根目录 | 自动检测（`run.lisp` 所在目录） | — | `MYAGENT_ROOT` |

> 开源仓库不包含任何个人记忆、密钥与二进制运行时。克隆下来即为空记忆状态，首次运行自动创建 `memory/`。

---

## 🔧 环境变量

| 变量 | 作用 |
|---|---|
| `DEEPSEEK_API_KEY` | DeepSeek API Key（也可用 `/model` 写入配置文件） |
| `DEEPSEEK_MODEL` | 模型名，默认 `deepseek-flash` |
| `DEEPSEEK_BASE_URL` | 接口地址，默认 `https://api.deepseek.com/anthropic` |
| `MYAGENT_SBCL` | 指定 SBCL 可执行文件路径（优先级低于 `bin/`） |
| `MYAGENT_ROOT` | 覆盖项目根目录 |
| `MYAGENT_MEMORY_DIR` | 覆盖记忆目录 |
| `MYAGENT_CONFIG` | 覆盖配置文件路径 |
| `MYAGENT_CURL` | 覆盖 curl 可执行文件名 |
| `NO_COLOR` | 禁用 ANSI 颜色输出 |

---

## 🔥 免重启实时自我迭代

1. **写入即热重载**：`write_file` / `append_file` 写入 `.lisp` 后立即 `load` 进当前镜像；
   若编译失败，则**自动回滚磁盘与内存到上一个可用版本**，并把错误回传给你（任务继续）。
2. **内存直接求值**：`eval_lisp` 可执行任意 S-表达式，第 N 轮注册的工具在第 N+1 轮即可调用。
3. **手动重载**：`/reload` 或 `reload_lisp` 工具。

> 默认**不会**每轮自动扫描磁盘上的 `.lisp`（避免任务中途被外部改动打断）。
> 需要时把 `*auto-reload-before-turn*` 设为 `t`。

---

## ⌨️ CLI 指令

| 指令 | 说明 |
|---|---|
| `/model` | 配置 DeepSeek API Key |
| `/tools` | 查看已注册工具 |
| `/reload` | 热重载全部核心模块 |
| `/md on\|off` | 开关 Markdown 渲染 |
| `/clear` | 清空对话上下文 |
| `/help` | 帮助 |
| `/exit` | 退出 |
| `,<s-expr>` 或 `/eval <s-expr>` | 直接求值 Common Lisp |

非交互用法：

```bash
sbcl --noinform --load run.lisp -- --prompt "你好"
sbcl --noinform --load run.lisp -- --eval-lisp "(+ 1 2)"
```

---

## 📦 体积参考

| 项 | 大小 |
|---|---|
| SBCL 运行时（`bin/`） | 约 48 MB（`sbcl.core` 31 MB + `contrib/` 14.5 MB + 可执行文件 2.3 MB） |
| 项目源码 | 约 200 KB |
| 运行内存 | 启动约 40 MB，加载全部模块约 100 MB |
