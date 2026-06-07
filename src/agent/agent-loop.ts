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
import { displayWidth } from "../utils/table-formatter";

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

// ── Pipe 表格自动修复 ────────────────────────

/**
 * 判断一行是否为 Markdown pipe 表格行。
 * 特征：以 | 开头和结尾，且包含至少一个内部 |
 */
function isPipeTableRow(line: string): boolean {
  const trimmed = line.trim();
  return trimmed.startsWith("|") && trimmed.endsWith("|") && trimmed.indexOf("|", 1) < trimmed.length - 1;
}

/**
 * 判断一行是否为 pipe 表格的分隔行。
 * 特征：只包含 |、-、:、空格 四种字符
 */
function isPipeSeparatorRow(line: string): boolean {
  return /^\|[\s\-:|]+\|$/.test(line.trim());
}

/**
 * 解析 pipe 表格的分隔行，返回每列的对齐方式。
 * 例如 "|:---|:---:|---:|" → ["left", "center", "right"]
 */
function parsePipeAlignments(sepLine: string): Array<"left" | "center" | "right"> {
  const cells = sepLine
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => c.trim());

  return cells.map((cell) => {
    const left = cell.startsWith(":");
    const right = cell.endsWith(":");
    if (left && right) return "center";
    if (right) return "right";
    return "left";
  });
}

/**
 * 解析一个 pipe 行，提取单元格内容（去除首尾 | 和首尾空格）。
 */
function parsePipeCells(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => c.trim());
}

/**
 * 使用 Unicode 框线字符构建表格。
 */
function buildBoxTable(
  headers: string[],
  rows: string[][],
  aligns: Array<"left" | "center" | "right">
): string {
  const colCount = headers.length;

  // 计算每列最大显示宽度
  const colWidths: number[] = [];
  for (let i = 0; i < colCount; i++) {
    let maxW = displayWidth(headers[i]);
    for (const row of rows) {
      const w = displayWidth(row[i] || "");
      if (w > maxW) maxW = w;
    }
    colWidths.push(Math.max(maxW, 2)); // 最小宽度 2
  }

  // 填充字符串到指定宽度
  function pad(str: string, targetW: number, align: string): string {
    const dw = displayWidth(str);
    const diff = targetW - dw;
    if (diff <= 0) return str;
    if (align === "right") return " ".repeat(diff) + str;
    if (align === "center") {
      const left = Math.floor(diff / 2);
      return " ".repeat(left) + str + " ".repeat(diff - left);
    }
    return str + " ".repeat(diff);
  }

  // 构建一行
  function rowLine(cells: string[]): string {
    return (
      "│ " +
      cells.map((c, i) => pad(c, colWidths[i], aligns[i] || "left")).join(" │ ") +
      " │"
    );
  }

  // 构建分隔线
  function sepLine(
    left: string,
    mid: string,
    right: string,
    fill: string
  ): string {
    return (
      left +
      colWidths.map((w) => fill.repeat(w + 2)).join(mid) +
      right
    );
  }

  const lines: string[] = [];
  lines.push(sepLine("┌", "┬", "┐", "─"));
  lines.push(rowLine(headers));
  lines.push(sepLine("├", "┼", "┤", "─"));
  for (const row of rows) {
    lines.push(rowLine(row));
  }
  lines.push(sepLine("└", "┴", "┘", "─"));

  return lines.join("\n");
}

/**
 * 🔧 检测并自动修复 Markdown pipe 表格。
 * 将文本中所有 pipe 表格替换为 Unicode 框线表格。
 * 非表格内容原样保留。
 */
function fixPipeTables(text: string): string {
  const lines = text.split("\n");
  const result: string[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // 检查是否是 pipe 表格的开始（当前行是 pipe 行，且下一行是分隔行）
    if (
      isPipeTableRow(line) &&
      !isPipeSeparatorRow(line) &&
      i + 1 < lines.length &&
      isPipeSeparatorRow(lines[i + 1])
    ) {
      // 收集表格的所有行
      const tableLines: string[] = [line];
      i++;

      // 跳过分隔行
      tableLines.push(lines[i]); // 分隔行
      i++;

      // 收集数据行（连续的 pipe 行）
      while (i < lines.length && isPipeTableRow(lines[i]) && !isPipeSeparatorRow(lines[i])) {
        tableLines.push(lines[i]);
        i++;
      }

      // 解析表格
      const headers = parsePipeCells(tableLines[0]);
      const aligns = parsePipeAlignments(tableLines[1]);
      const dataRows = tableLines.slice(2).map(parsePipeCells);

      // 确保列数一致
      const colCount = headers.length;
      const safeAligns = aligns.length === colCount ? aligns : headers.map(() => "left" as const);

      // 转换为 Unicode 框线表格
      const boxTable = buildBoxTable(headers, dataRows, safeAligns);
      result.push(boxTable);
    } else {
      result.push(line);
      i++;
    }
  }

  return result.join("\n");
}

// ── Agent 主循环 ─────────────────────────────

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
    const content: any[] = response.content || [];

    messages.push({ role: "assistant", content });

    const toolUses = content.filter(
      (b: any) => b.type === "tool_use"
    ) as Array<{
      type: "tool_use";
      id: string;
      name: string;
      input: Record<string, unknown>;
    }>;

    console.log(
      `  🔄 Turn ${turns} | stop_reason=${stopReason} | tools=${toolUses.length} | content_blocks=${content.length}`
    );

    if (stopReason === "tool_use" && toolUses.length > 0) {
      // 执行工具调用
      const toolResults: Array<{ type: string; tool_use_id: string; content: string }> = [];

      for (const tc of toolUses) {
        console.log(
          `  🔧 调用工具: ${tc.name}(${formatArgsForLog(tc.input)})`
        );

        try {
          let result: unknown;
          if (isAsyncTool(tc.name)) {
            result = await executeTool(tc.name, tc.input);
          } else {
            result = executeTool(tc.name, tc.input);
          }

          const resultStr =
            typeof result === "string" ? result : JSON.stringify(result, null, 2);
          toolResults.push({
            type: "tool_result",
            tool_use_id: tc.id,
            content: resultStr,
          });
        } catch (err: any) {
          toolResults.push({
            type: "tool_result",
            tool_use_id: tc.id,
            content: `❌ 工具执行失败: ${err.message}`,
          });
        }
      }

      messages.push({ role: "user", content: toolResults });
    } else {
      // 最终回答
      const textBlocks = content.filter(
        (b: any) => b.type === "text" && b.text
      );
      const rawAnswer = textBlocks.map((b: any) => b.text).join("\n");

      // 🔧 自动修复 pipe 表格
      const answer = fixPipeTables(rawAnswer);

      console.log(`  ✅ 回答 (${answer.length} 字符)`);
      return { answer, history: messages };
    }
  }

  // 达到最大轮数限制
  return {
    answer: "⚠️ 达到最大轮数限制，已停止思考。",
    history: messages,
  };
}
