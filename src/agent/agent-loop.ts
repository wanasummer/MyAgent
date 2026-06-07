/**
 * 核心 Agent 循环 (ReAct Loop)。
 *
 * 🧠 记忆功能（RAG 升级版）：
 *   1. 会话记忆 — 传入对话历史
 *   2. 持久化记忆 — 全部记忆摘要注入 system prompt
 *   3. 🔍 RAG 语义检索 — 每轮对话动态检索与用户输入最相关的片段
 *
 * 🔌 MCP 集成：
 *   4. MCP Manager — 管理外部 MCP Server，动态发现和调用工具
 *
 * 🛡️ 所有路径动态获取（os.homedir()），不硬编码。
 */

import * as os from "os";
import * as path from "path";
import { chatWithTools } from "./llm-client";
import { SYSTEM_PROMPT } from "./system-prompt";
import { TOOL_DEFINITIONS, ToolDefinition } from "./tool-definitions";
import { executeTool, isAsyncTool } from "../tool-executor";
import { formatMemoryContext, searchMemories } from "../memory/memory-store";
import { getMcpManager } from "../mcp/mcp-manager";

const MAX_TURNS = 40;

/** MCP 是否已初始化 */
let mcpInitialized = false;
/** MCP 初始化 Promise（防止并发初始化） */
let mcpInitPromise: Promise<void> | null = null;

function buildContext(): string {
  const homeDir = os.homedir();
  const desktopDir = path.join(homeDir, "Desktop");
  const projectDir = process.cwd();

  return [
    `## 当前环境`,
    `- 你的工作目录（项目目录）：\`${projectDir}\``,
    `- 用户主目录：\`${homeDir}\``,
    `- 用户桌面：\`${desktopDir}\``,
    `- 用户说的"桌面"就是 \`${desktopDir}\``,
    `- 用户说的"代码项目"、"快捷方式"等分类文件夹，大概率在桌面上，先用 \`list_directory\` 查看 \`${desktopDir}\` 确认`,
    `- 路径中的 \`~\` 会被自动展开为 \`${homeDir}\``,
  ].join("\n");
}

/**
 * 构建完整 system prompt（含环境 + 记忆摘要 + RAG 检索）。
 */
function buildSystemPrompt(userInput?: string): string {
  let prompt = SYSTEM_PROMPT
    .replace("{{CONTEXT}}", buildContext())
    .replace("{{MEMORY}}", formatMemoryContext())
    .replace("{{PROJECT_DIR}}", process.cwd())
    .replace("{{HOME_DIR}}", os.homedir())
    .replace("{{DESKTOP_DIR}}", path.join(os.homedir(), "Desktop"));

  // 🔍 RAG: 动态检索与当前输入相关的记忆片段
  if (userInput) {
    try {
      const ragResults = searchMemories(userInput, 5);
      if (ragResults) {
        prompt += "\n" + ragResults;
      }
    } catch {
      // 检索失败不影响主流程
    }
  }

  return prompt;
}

/** 确保 MCP Manager 已初始化（lazy, 只初始化一次） */
async function ensureMcpInitialized(): Promise<void> {
  if (mcpInitialized) return;

  if (mcpInitPromise) {
    await mcpInitPromise;
    return;
  }

  mcpInitPromise = (async () => {
    try {
      await getMcpManager().initialize();
      mcpInitialized = true;
    } catch (err: any) {
      console.log(`  ⚠️ MCP 初始化失败: ${err.message}`);
      mcpInitialized = true;
    }
  })();

  await mcpInitPromise;
}

export interface AgentResult {
  answer: string;
  history: Array<{ role: string; content: unknown }>;
}

/**
 * 格式化工具参数用于日志输出。
 * 对 content、text 等长文本参数截断显示，避免满屏 \n。
 */
function formatArgsForLog(args: Record<string, unknown>): string {
  const maxLen = 120;
  const display: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(args)) {
    if (typeof value === "string" && value.length > maxLen) {
      // 长文本：显示前 maxLen 字符 + 统计信息
      const lines = value.split("\n").length;
      display[key] =
        value.slice(0, maxLen).replace(/\n/g, "↵") +
        `… (共 ${value.length} 字符, ${lines} 行)`;
    } else {
      display[key] = value;
    }
  }

  return JSON.stringify(display);
}

/**
 * 运行一次 Agent 对话。
 */
export async function runAgent(
  userInput: string,
  history?: Array<{ role: string; content: unknown }>
): Promise<AgentResult> {
  // 🔌 懒初始化 MCP
  await ensureMcpInitialized();

  // 🔌 获取 MCP 工具并合并
  const mcpTools = getMcpManager().getAllToolDefs();
  const allTools: ToolDefinition[] = [...TOOL_DEFINITIONS, ...mcpTools];

  const systemPrompt = buildSystemPrompt(userInput);

  const messages: Array<{ role: string; content: unknown }> = history
    ? [...history, { role: "user", content: userInput }]
    : [{ role: "user", content: userInput }];

  let turns = 0;

  while (turns < MAX_TURNS) {
    turns++;

    const response = await chatWithTools({
      system: systemPrompt,
      messages,
      tools: allTools,
    });

    const stopReason: string = response.stop_reason;
    const content = response.content;

    messages.push({ role: "assistant", content });

    const toolUses = content.filter(
      (b: any) => b.type === "tool_use"
    ) as Array<{
      type: "tool_use";
      id: string;
      name: string;
      input: Record<string, unknown>;
    }>;

    if (stopReason === "tool_use" && toolUses.length > 0) {
      const toolResults: unknown[] = [];

      for (const tc of toolUses) {
        const toolName = tc.name;
        const toolArgs = tc.input || {};

        console.log(
          `  🔧 [第 ${turns} 轮] 调用工具: ${toolName}(${formatArgsForLog(toolArgs)})`
        );

        let result: unknown;

        // 🔌 MCP 工具路由：以 mcp__ 前缀开头
        if (toolName.startsWith("mcp__")) {
          result = await getMcpManager().callTool(toolName, toolArgs);
        } else if (isAsyncTool(toolName)) {
          result = await (executeTool(toolName, toolArgs) as Promise<unknown>);
        } else {
          result = executeTool(toolName, toolArgs);
        }

        const resultStr = JSON.stringify(result, null, 2);
        const truncated =
          resultStr.length > 4000
            ? resultStr.slice(0, 4000) + "\n...(结果已截断)"
            : resultStr;

        toolResults.push({
          type: "tool_result",
          tool_use_id: tc.id,
          content: truncated,
        });
      }

      messages.push({ role: "user", content: toolResults });
      continue;
    }

    // 最终回答 — 提取文本块，确保换行符正确渲染不被压缩
    const textBlocks = content.filter(
      (b: any) => b.type === "text"
    ) as Array<{ type: "text"; text: string }>;

    const answer = textBlocks.map((b) => b.text).join("\n");

    return { answer, history: messages };
  }

  return {
    answer: "⚠️ 达到最大轮数限制，已停止思考。",
    history: messages,
  };
}
