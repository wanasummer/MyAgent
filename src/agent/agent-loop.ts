/**
 * 核心 Agent 循环 (ReAct Loop)。
 *
 * Anthropic Messages API 格式：
 *   - system 是顶层参数（不是 message）
 *   - tool 调用在 assistant content 块中（type: "tool_use"）
 *   - tool 结果作为 user message 返回（type: "tool_result"）
 *   - stop_reason 指示 "tool_use" 或 "end_turn"
 */

import * as os from "os";
import { chatWithTools } from "./llm-client";
import { SYSTEM_PROMPT } from "./system-prompt";
import { TOOL_DEFINITIONS } from "./tool-definitions";
import { executeTool } from "../tool-executor";

const MAX_TURNS = 10;

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

const RESOLVED_SYSTEM_PROMPT = SYSTEM_PROMPT.replace(
  "{{CONTEXT}}",
  buildContext()
)
  .replace("{{PROJECT_DIR}}", process.cwd())
  .replace("{{HOME_DIR}}", os.homedir())
  .replace("{{DESKTOP_DIR}}", `${os.homedir()}\\Desktop`);

export async function runAgent(userInput: string): Promise<string> {
  const systemPrompt = RESOLVED_SYSTEM_PROMPT;

  const messages: Array<{ role: string; content: unknown }> = [
    { role: "user", content: userInput },
  ];

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
    return (
      textBlocks.map((b) => b.text).join("\n") ||
      "（Agent 没有返回内容）"
    );
  }

  return "⚠️ 已达到最大执行轮次 (10)，任务可能未完成。请尝试简化你的请求。";
}
