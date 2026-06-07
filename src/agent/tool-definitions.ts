/**
 * Anthropic-compatible tool definitions for the DeepSeek Anthropic API.
 * Uses input_schema (Anthropic format) instead of parameters (OpenAI format).
 */

export interface ToolDefinition {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export const TOOL_DEFINITIONS: ToolDefinition[] = [
  {
    name: "list_directory",
    description:
      "列出指定目录下的所有文件和子目录。返回文件名、路径、大小、类型等信息。" +
      "在操作任何文件之前，先用此工具了解目录结构。",
    input_schema: {
      type: "object",
      properties: {
        dirPath: {
          type: "string",
          description: "要列出的目录路径（绝对路径），默认为当前工作目录 '.'",
        },
        recursive: {
          type: "boolean",
          description: "是否递归列出子目录的内容，默认为 false",
        },
      },
      required: ["dirPath"],
    },
  },
  {
    name: "read_file",
    description: "读取指定文件的全部内容，以 UTF-8 文本返回。",
    input_schema: {
      type: "object",
      properties: {
        filePath: {
          type: "string",
          description: "要读取的文件路径（绝对路径）",
        },
      },
      required: ["filePath"],
    },
  },
  {
    name: "write_file",
    description:
      "创建新文件或覆写已有文件，写入指定的文本内容。如果父目录不存在会自动创建。",
    input_schema: {
      type: "object",
      properties: {
        filePath: {
          type: "string",
          description: "要创建/覆写的文件路径（绝对路径）",
        },
        content: {
          type: "string",
          description: "要写入文件的内容",
        },
      },
      required: ["filePath", "content"],
    },
  },
  {
    name: "search_text",
    description: "在指定文件中搜索包含目标文本的行，返回匹配行及其行号。",
    input_schema: {
      type: "object",
      properties: {
        filePath: {
          type: "string",
          description: "要搜索的文件路径（绝对路径）",
        },
        searchText: {
          type: "string",
          description: "要搜索的关键词或文本",
        },
      },
      required: ["filePath", "searchText"],
    },
  },
  {
    name: "search_files",
    description:
      "在目录中搜索文件名匹配指定模式的文件。支持字符串模糊匹配或正则表达式。",
    input_schema: {
      type: "object",
      properties: {
        dirPath: {
          type: "string",
          description: "要搜索的目录路径（绝对路径）",
        },
        pattern: {
          type: "string",
          description:
            "搜索模式，例如 '.log' 会匹配所有包含 .log 的文件名，或使用正则如 '\\.txt$'",
        },
        recursive: {
          type: "boolean",
          description: "是否递归搜索子目录，默认为 true",
        },
      },
      required: ["dirPath", "pattern"],
    },
  },
  {
    name: "get_file_info",
    description:
      "获取单个文件的详细信息，包括大小、最后修改时间、是否为目录等。",
    input_schema: {
      type: "object",
      properties: {
        filePath: {
          type: "string",
          description: "要查询的文件路径（绝对路径）",
        },
      },
      required: ["filePath"],
    },
  },
  {
    name: "append_file",
    description:
      "向已有文件末尾追加一行文本内容。如果文件不存在则创建。",
    input_schema: {
      type: "object",
      properties: {
        filePath: {
          type: "string",
          description: "要追加内容的文件路径（绝对路径）",
        },
        content: {
          type: "string",
          description: "要追加的内容",
        },
      },
      required: ["filePath", "content"],
    },
  },
  {
    name: "copy_file",
    description:
      "将单个文件从源路径复制到目标路径。只能复制文件，不能复制目录。如目标目录不存在会自动创建。",
    input_schema: {
      type: "object",
      properties: {
        source: {
          type: "string",
          description: "源文件路径（绝对路径）",
        },
        destination: {
          type: "string",
          description: "目标文件路径（绝对路径）",
        },
      },
      required: ["source", "destination"],
    },
  },
  {
    name: "move_path",
    description:
      "移动文件或整个目录到新位置（同盘符下是瞬间完成）。适用于：用户说「把 X 移到 Y」、「把 X 归入 Y 文件夹」、「整理文件」等场景。可以移动文件和目录。目标路径的父目录必须存在。",
    input_schema: {
      type: "object",
      properties: {
        source: {
          type: "string",
          description: "源文件或目录的绝对路径",
        },
        destination: {
          type: "string",
          description: "目标路径（绝对路径），包含目标文件名或目录名",
        },
      },
      required: ["source", "destination"],
    },
  },
  {
    name: "save_memory",
    description:
      "保存一条持久化记忆。记忆会存储在 ~/.myagent/memory/ 目录中，跨会话保留。" +
      "当你发现用户的重要偏好、习惯、常用路径、项目信息、或用户明确要求「记住」时，应主动调用此工具。",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "记忆名称（kebab-case 格式，如 'user-preferred-editor'）",
        },
        description: {
          type: "string",
          description: "一行概要，用于判断记忆相关性",
        },
        type: {
          type: "string",
          enum: ["user", "feedback", "project", "reference"],
          description: "记忆类型：user=用户偏好, feedback=用户反馈, project=项目信息, reference=参考信息",
        },
        content: {
          type: "string",
          description: "记忆的完整内容，用 Markdown 格式书写",
        },
      },
      required: ["name", "description", "type", "content"],
    },
  },
  {
    name: "recall_memory",
    description:
      "读取某条记忆的完整内容。当用户提到「上次」「之前」「像以前那样」或你需要回忆过去的重要信息时使用。",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "要读取的记忆名称",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "list_memories",
    description: "列出所有已保存的持久化记忆摘要。",
    input_schema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "delete_memory",
    description: "删除一条持久化记忆。删除前必须得到用户的明确同意！",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "要删除的记忆名称",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "delete_path",
    description:
      "删除文件或目录。如果是目录则递归删除其下所有内容。请谨慎使用！删除前必须确认用户意图。",
    input_schema: {
      type: "object",
      properties: {
        target: {
          type: "string",
          description: "要删除的文件或目录路径（绝对路径）",
        },
      },
      required: ["target"],
    },
  },
  // 🔍 RAG: 语义记忆检索
  {
    name: "search_memories",
    description:
      "语义搜索持久化记忆。通过 RAG 向量检索找到与查询最相关的记忆片段。" +
      "当用户问「我们之前聊过什么」「有没有相关的记忆」「还记得...」时使用。" +
      "与 recall_memory 不同：recall_memory 需要精确的记忆名称，search_memories 用自然语言语义搜索。",
    input_schema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "要搜索的查询文本（自然语言描述即可）",
        },
        topK: {
          type: "number",
          description: "返回 top-K 个最相关结果（默认 5）",
        },
      },
      required: ["query"],
    },
  },
];
