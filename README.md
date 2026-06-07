# 🤖 MyAgent — 本地文件管理 & 自我迭代助手

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.6-blue)](https://www.typescriptlang.org/)
[![Node.js](https://img.shields.io/badge/Node.js-%3E%3D18-green)](https://nodejs.org/)

> 用自然语言操控本地文件系统。ReAct 推理循环 + 持久化 RAG 记忆 + MCP 协议扩展 + 自我代码迭代。

MyAgent 是一个运行在终端中的 AI 助手，你只需用中文（或英文）描述你想做的事情，它会自主思考、调用工具、观察结果，最终给你答案。

```
👤 你: 桌面有哪些文件夹？
🤖 正在思考...
   🔧 list_directory → C:\Users\XTW\Desktop
🤖 ✅ 你的桌面有以下文件夹：
   - 代码项目
   - 文档资料
   - 快捷方式
```

---

## ✨ 核心特性

- 🧠 **ReAct 推理循环** — Thought → Action → Observation → Answer，LLM 自主决策调用哪些工具
- 📁 **完整文件管理** — 列出目录、读写文件、搜索内容、复制移动、删除等 10+ 工具
- 💾 **持久化记忆 + RAG** — 文件式记忆存储 + 本地 TF-IDF 语义检索，跨会话保留
- 🔌 **MCP 协议支持** — Model Context Protocol，通过 stdio 扩展外部工具
- 🔄 **自我迭代** — Agent 可以读取和修改自己的 TypeScript 源代码
- 🎨 **CLI 交互界面** — 彩色终端输出，支持对话历史和特殊命令
- 🛡️ **跨平台兼容** — 所有路径动态获取，不硬编码，Windows/macOS/Linux 均可运行
- 📊 **内置 MCP 工具** — 磁盘占用查询，生成对齐的 Unicode 框线表格

---

## 🚀 快速开始

### 前提条件

- **Node.js** >= 18
- **DeepSeek API Key** — 从 [platform.deepseek.com](https://platform.deepseek.com/) 获取

### 安装

```bash
# 克隆仓库
git clone https://github.com/your-username/myagent.git
cd myagent

# 安装依赖
npm install

# 构建
npm run build
```

### 配置 API Key

三种方式任选其一：

```bash
# 方式一（推荐）: 写入全局配置
echo DEEPSEEK_API_KEY=sk-your-api-key > ~/.myagent/config

# 方式二: 项目目录下创建 .env
cp .env.example .env
# 然后编辑 .env 填入你的 Key

# 方式三: 系统环境变量
setx DEEPSEEK_API_KEY sk-your-api-key   # Windows
export DEEPSEEK_API_KEY=sk-your-api-key # macOS/Linux
```

### 运行

```bash
# 开发模式
npm run dev

# 或构建后运行
npm run build
node dist/main.js

# 全局安装后直接使用
npm install -g .
myagent
```

---

## 💬 使用示例

```
🤖 MyAgent — 自我迭代助手
   用自然语言操作文件、管理记忆、迭代自身代码。
   🧠 RAG 记忆: ~/.myagent/memory/ (本地 TF-IDF 语义检索)
   命令: /memories | /search <关键词> | /rag-rebuild | /forget <name> | clear | exit

👤 你: 帮我把桌面上所有 .pdf 文件找出来
🤖 ✅ 找到 3 个 PDF 文件：
   - C:\Users\XTW\Desktop\报告.pdf (2.4 MB)
   - C:\Users\XTW\Desktop\合同.pdf (856 KB)
   - C:\Users\XTW\Desktop\简历.pdf (1.1 MB)

👤 你: 在桌面建一个"PDF归档"文件夹，把这三个 PDF 移进去
🤖 ✅ 已创建 C:\Users\XTW\Desktop\PDF归档 文件夹
   ✅ 已将 3 个 PDF 文件移入 PDF归档

👤 你: 记住，PDF归档是重要的工作文档
🤖 ✅ 已保存记忆: pdf-archive-important

👤 你: 查一下各盘空间
🤖 🔌 [MCP:disk] 已连接
┌────────┬──────────────┬───────────┬───────────┬───────────┬─────────┐
│ 盘符   │ 卷标         │   总容量  │     已用  │     剩余  │  使用率 │
├────────┼──────────────┼───────────┼───────────┼───────────┼─────────┤
│ C:     │ Windows-SSD  │ 200.00 GB │ 168.40 GB │  31.60 GB │  84.20% │
│ D:     │ Data         │ 275.69 GB │ 263.44 GB │  12.25 GB │  95.56% │
└────────┴──────────────┴───────────┴───────────┴───────────┴─────────┘
```

### 特殊命令

| 命令 | 说明 |
|------|------|
| `/memories` | 列出所有持久化记忆 |
| `/search <关键词>` | 语义搜索记忆（RAG） |
| `/rag-rebuild` | 重建 RAG 向量索引 |
| `/forget <name>` | 删除指定记忆 |
| `clear` | 清除当前对话历史 |
| `exit` / `quit` | 退出 |

---

## 🏗️ 架构

```
┌─────────────────────────────────────────────┐
│                   MyAgent                    │
├─────────────────────────────────────────────┤
│  CLI (readline)                             │
│      │                                       │
│  ┌───▼──────────────────────────────────┐   │
│  │        Agent Loop (ReAct)             │   │
│  │  Thought → Action → Observation       │   │
│  │       → Answer                        │   │
│  └───┬──────────────┬───────────────────┘   │
│      │              │                        │
│  ┌───▼───┐    ┌─────▼──────┐               │
│  │ LLM   │    │  Tool      │               │
│  │Client │    │  Executor  │               │
│  │(Deep- │    │            │               │
│  │ Seek) │    │ ┌────────┐ │               │
│  └───────┘    │ │ 文件   │ │               │
│               │ │ 工具   │ │               │
│               │ ├────────┤ │               │
│               │ │ 记忆   │ │               │
│               │ │ 系统   │ │               │
│               │ ├────────┤ │               │
│               │ │ MCP    │ │               │
│               │ │ 路由   │ │               │
│               │ └────────┘ │               │
│               └─────┬──────┘               │
│                     │                       │
│  ┌──────────────────┼──────────────────┐   │
│  │     MCP Manager                      │   │
│  │  ┌─────────┐  ┌─────────┐           │   │
│  │  │ disk    │  │ future  │  ...      │   │
│  │  │ server  │  │ servers │           │   │
│  │  └─────────┘  └─────────┘           │   │
│  └──────────────────────────────────────┘   │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │     Memory System (~/.myagent/)      │   │
│  │  ┌──────────┐  ┌──────────────┐     │   │
│  │  │ 文件存储  │  │ RAG 向量索引  │     │   │
│  │  │ .md 文件  │  │ TF-IDF n-gram│     │   │
│  │  └──────────┘  └──────────────┘     │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

### 项目结构

```
MyAgent/
├── src/
│   ├── main.ts                  # 入口：CLI、配置加载
│   ├── tool-executor.ts        # 工具执行调度
│   ├── agent/
│   │   ├── agent-loop.ts       # ReAct 核心循环
│   │   ├── system-prompt.ts    # 系统提示词模板
│   │   ├── tool-definitions.ts # 内置工具定义
│   │   └── llm-client.ts       # DeepSeek API 客户端
│   ├── memory/
│   │   ├── memory-store.ts     # 持久化记忆管理
│   │   └── rag-store.ts        # 本地 TF-IDF RAG 检索
│   ├── mcp/
│   │   ├── mcp-manager.ts      # MCP Server 管理器
│   │   ├── mcp-client.ts       # JSON-RPC 客户端
│   │   └── servers/
│   │       └── disk-usage-server.ts  # 内置磁盘查询 Server
│   └── utils/
│       ├── file-utils.ts       # 文件操作工具
│       └── table-formatter.ts  # Unicode 表格格式化
├── .env.example                # 环境变量模板
├── package.json
├── tsconfig.json
└── README.md
```

---

## 🛠️ 内置工具

| 工具 | 说明 |
|------|------|
| `list_directory` | 列出目录内容 |
| `read_file` | 读取文件 |
| `write_file` | 创建/覆写文件 |
| `append_file` | 追加内容到文件 |
| `search_text` | 在文件中搜索文本 |
| `search_files` | 按文件名模式搜索 |
| `get_file_info` | 获取文件详细信息 |
| `copy_file` | 复制文件 |
| `move_path` | 移动文件/目录 |
| `delete_path` | 删除文件/目录 |
| `list_memories` | 列出所有记忆 |
| `recall_memory` | 读取指定记忆 |
| `save_memory` | 保存新记忆 |
| `delete_memory` | 删除记忆 |
| `search_memories` | RAG 语义搜索记忆 |
| `mcp__disk__get_disk_usage` | 查询磁盘占用 (MCP) |

---

## 🧠 记忆系统

MyAgent 拥有一套**双重记忆系统**：

### 1. 文件存储（主）
- 记忆以 Markdown 文件存储在 `~/.myagent/memory/`
- 支持 frontmatter 元数据（name, description, type）
- 自动维护 `MEMORY.md` 索引文件
- 四种记忆类型：`user`（偏好）、`project`（项目）、`feedback`（反馈）、`reference`（参考）

### 2. RAG 语义检索（辅）
- 本地 **TF-IDF n-gram** 向量化，零外部依赖
- 每次对话自动检索与用户输入最相关的记忆
- 向量索引存储在 `~/.myagent/memory/vectors.json`
- 保存/删除记忆时自动更新索引

Agent 会在每轮对话中自动注入相关记忆片段，让对话更有"记忆感"。

---

## 🔄 自我迭代

MyAgent 可以**读取和修改自己的源代码**。这意味着你可以：

```
👤 你: 给 MyAgent 增加一个统计文件夹大小的功能
🤖 我会：
   1. 读取 src/utils/file-utils.ts 了解现有工具
   2. 读取 src/agent/tool-definitions.ts 了解工具注册
   3. 设计 folder_size 工具
   4. 编辑相关文件
   5. 提醒你运行 npm run build 编译

   需要我开始实施吗？
```

这是 MyAgent 区别于其他助手的关键特性——它能**自我进化**。

---

## 🔌 MCP 协议扩展

MyAgent 实现了 **Model Context Protocol (MCP)**，通过 stdio + JSON-RPC 2.0 连接外部工具服务器。

### 内置 MCP Server

- **disk-usage-server** — 跨平台磁盘占用查询
  - Windows: 使用 `wmic` 命令
  - macOS/Linux: 使用 `df` 命令
  - 返回预格式化的 Unicode 框线表格

### 开发自定义 MCP Server

MCP Server 是一个独立的 Node.js 进程，通过 stdin/stdout 与 MyAgent 通信。参考 `src/mcp/servers/disk-usage-server.ts` 的实现：

1. 实现 `initialize`、`tools/list`、`tools/call` 三个 JSON-RPC 方法
2. 在 `mcp-manager.ts` 中注册你的 Server
3. 重启 MyAgent，工具自动可用

---

## ⚙️ 配置参考

| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `DEEPSEEK_API_KEY` | **必填**，DeepSeek API Key | - |
| `DEEPSEEK_BASE_URL` | API 端点 | `https://api.deepseek.com/anthropic` |
| `DEEPSEEK_MODEL` | 模型名 | `deepseek-v4-pro` |
| `DEBUG` | 开启调试日志 | - |

配置加载优先级：**项目目录 `.env` > `~/.myagent/config` > 系统环境变量**

---

## 🧑‍💻 开发

```bash
# 安装依赖
npm install

# 开发模式（热重载）
npm run dev

# 构建
npm run build

# 运行测试
npm test
```

### 技术栈

- **TypeScript 5.6** — 类型安全
- **DeepSeek API** (Anthropic 兼容) — LLM 后端
- **Commander** — CLI 框架
- **Chalk** — 终端颜色
- **Inquirer** — 交互式输入
- **TF-IDF** — 本地向量检索（零外部依赖）

---

## 📄 许可证

MIT © [Your Name]

---

## 🙏 致谢

- [DeepSeek](https://www.deepseek.com/) — 提供高性能、低成本的 LLM API
- [Anthropic](https://www.anthropic.com/) — Claude 的 Tool Use 设计启发了本项目的工具系统
- [Model Context Protocol](https://modelcontextprotocol.io/) — 标准化的 AI-工具通信协议

---

> 💡 **提示**: MyAgent 是自我迭代的！如果你觉得哪里可以改进，直接告诉它，它可以自己改代码。
