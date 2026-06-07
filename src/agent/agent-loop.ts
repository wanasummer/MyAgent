/**
 * 核心 Agent 循环 (ReAct Loop)。
 *
 * Anthropic Messages API 格式：
 *   - system 是顶层参数（不是 message）
 *   - tool 调用在 assistant content 块中（type: "tool_use"）
 *   - tool 结果作为 user message 返回（type: "tool_result"）
 *   - stop_reason 指示 "tool_use" 或 "end_turn"
 *
 * 🧠 记忆功能：
 *   1. 会话记忆 — 传入对话历史 (history)，让 Agent 记住之前和用户说过的话。
 *   2. 持久化记忆 — 加载 ~/.myagent/memory/ 中的记忆文件，注入 system prompt。
 */

import * as os from "os";
import { chatWithTools } from "./llm-client";
import { SYSTEM_PROMPT } from "./system-prompt";
import { TOOL_DEFINITIONS } from "./tool-definitions";
import { executeTool } from "../tool-executor";
import { formatMemoryContext } from "../memory/memory-store";

const MAX_TURNS = 20;

/**
 * 构建运行时上下文，注入到系统提示词中。
 */
function buildContext(): string {
  const homeDir = os.homedir();
  const desktopDir = `${homeDir}\\Desktop`;
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
 * 构建完整的 system prompt（含环境上下文 + 持久化记忆）。
 */
function buildSystemPrompt(): string {
  return SYSTEM_PROMPT.replace("{{CONTEXT}}", buildContext())
    .replace("{{MEMORY}}", formatMemoryContext())
    .replace("{{PROJECT_DIR}}", process.cwd())
    .replace("{{HOME_DIR}}", os.homedir())
    .replace("{{DESKTOP_DIR}}", `${os.homedir()}\\Desktop`);
}

export interface AgentResult {
  /** 最终回答文本 */
  answer: string;
  /** 更新后的完整对话历史（包含本轮 user 输入、assistant 工具调用、最终回答），传给下一轮 */
  history: Array<{ role: string; content: unknown }>;
}

/**
 * 运行一次 Agent 对话。
 *
 * @param userInput 用户输入文本
 * @param history   可选的历史消息列表。传入后可让 Agent 记住之前的对话。
 * @returns AgentResult，包含回答和更新后的历史
 */
export async function runAgent(
  userInput: string,
  history?: Array<{ role: string; content: unknown }>
): Promise<AgentResult> {
  const systemPrompt = buildSystemPrompt();

  // 🧠 如果有历史消息，则在此基础上追加；否则新建
  const messages: Array<{ role: string; content: unknown }> = history
    ? [...history, { role: "user", content: userInput }]
    : [{ role: "user", content: userInput }];

  let turns = 0;

  while (turns < MAX_TURNS) {
    turns++;

    const response = await chatWithTools({
      system: systemPrompt,
      messages,
      tools: TOOL_DEFINITIONS,
    });

    const stopReason: string = response.stop_reason;
    const content = response.content;

    // 存 assistant 消息
    messages.push({ role: "assistant", content });

    // 收集 tool_use
    const toolUses = content.filter((b: any) => b.type === "tool_use") as Array<{
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
          `  🔧 [第 ${turns} 轮] 调用工具: ${toolName}(${JSON.stringify(toolArgs)})`
        );

        const result = executeTool(toolName, toolArgs);

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

    // 最终回答
    const textBlocks = content.filter((b: any) => b.type === "text") as Array<{ type: "text"; text: string }>;
    const answer =
      textBlocks.map((b) => b.text).join("\n") ||
      "（Agent 没有返回内容）";

    return { answer, history: messages };
  }

  return {
    answer: "⚠️ 已达到最大执行轮次 (10)，任务可能未完成。请尝试简化你的请求。",
    history: messages,
  };
}
