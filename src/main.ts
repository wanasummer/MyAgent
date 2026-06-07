#!/usr/bin/env node

/**
 * MyAgent — 本地文件管理 & 分析助手
 *
 * 输入人话 → Agent 自动拆解步骤 → 调用工具操作文件 → 返回中文结果
 * 支持交互式对话模式，并且带记忆功能。
 *
 * 用法:
 *   myagent                 （全局安装后）
 *   npx ts-node src/main.ts （开发时）
 *
 * 配置优先级（由高到低）:
 *   1. 当前目录的 .env 文件
 *   2. 用户主目录的 .myagent 文件
 *   3. 系统环境变量 DEEPSEEK_API_KEY
 */

import * as path from "node:path";
import * as os from "node:os";
import * as fs from "node:fs";
import * as readline from "node:readline";
import dotenv from "dotenv";
import chalk from "chalk";
import { runAgent } from "./agent/agent-loop";
import { initMemoryDir, loadMemories, deleteMemory } from "./memory/memory-store";

// ── 目录迁移：旧版 ~/.myagent 是文件 → 新版 ~/.myagent/config ──
const MYAGENT_DIR = path.join(os.homedir(), ".myagent");
const MYAGENT_CONFIG = path.join(MYAGENT_DIR, "config");
const OLD_CONFIG = path.join(os.homedir(), ".myagent");

// 如果旧的 ~/.myagent 是文件，迁移为 ~/.myagent/config
if (fs.existsSync(OLD_CONFIG) && fs.statSync(OLD_CONFIG).isFile()) {
  if (!fs.existsSync(MYAGENT_DIR)) {
    fs.mkdirSync(MYAGENT_DIR, { recursive: true });
  }
  const content = fs.readFileSync(OLD_CONFIG, "utf-8");
  fs.writeFileSync(MYAGENT_CONFIG, content, "utf-8");
  fs.unlinkSync(OLD_CONFIG);
}

// ── 多层级加载 env ──────────────────────────
// 优先级：~/.myagent/config > CWD/.env > 系统环境变量
dotenv.config();                                                        // 1. 当前目录 .env
dotenv.config({ path: MYAGENT_CONFIG, override: true });                // 2. 全局 ~/.myagent/config

async function main() {
  // ── 环境检查 ──────────────────────────────
  if (!process.env.DEEPSEEK_API_KEY) {
    console.error(chalk.red("❌ 未设置 DEEPSEEK_API_KEY"));
    console.error(chalk.gray("   方式一（推荐）: echo DEEPSEEK_API_KEY=你的key > %USERPROFILE%\\.myagent\\config"));
    console.error(chalk.gray("   方式二: 在当前目录创建 .env 文件"));
    console.error(chalk.gray("   方式三: setx DEEPSEEK_API_KEY 你的key"));
    process.exit(1);
  }

  // 🧠 初始化持久化记忆目录
  initMemoryDir();

  // 调试：确认 Key 加载正确（只显示首尾）
  const key = process.env.DEEPSEEK_API_KEY || "";
  const masked = key.length > 12
    ? key.slice(0, 8) + "****" + key.slice(-4)
    : "****";
  console.log(chalk.gray(`  🔑 已加载 Key: ${masked} (长度: ${key.length})`));
  console.log(chalk.gray(`  🌐 API: ${process.env.DEEPSEEK_BASE_URL || "默认"}`));
  console.log(chalk.gray(`  🤖 模型: ${process.env.DEEPSEEK_MODEL || "默认"}`));

  // ── CLI 界面 ──────────────────────────────
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  console.log(chalk.cyan.bold("\n🤖 MyAgent — 本地文件管理助手"));
  console.log(chalk.gray("   用自然语言告诉我你想做什么，我会自动操作文件系统。"));
  console.log(chalk.gray("   🧠 持久化记忆: ~/.myagent/memory/  (类似 Claude Code 的 memory)"));
  console.log(chalk.gray("   命令: clear(清除会话)  /memories(查看记忆)  /forget <name>(删除记忆)"));
  console.log(chalk.gray('         /remember <内容>(保存记忆)  exit(退出)\n'));

  // 🧠 对话历史记忆 — 在 Agent 整个生命周期中维护
  let conversationHistory: Array<{ role: string; content: unknown }> = [];

  const ask = () => {
    rl.question(chalk.green("👤 你: "), async (input) => {
      const trimmed = input.trim();

      if (trimmed === "") {
        ask();
        return;
      }

      // 清除会话记忆
      if (trimmed.toLowerCase() === "clear") {
        conversationHistory = [];
        console.log(chalk.yellow("  🧹 对话记忆已清除。\n"));
        ask();
        return;
      }

      // 列出持久化记忆
      if (trimmed.toLowerCase() === "/memories" || trimmed.toLowerCase() === "/memory") {
        const memories = loadMemories();
        if (memories.length === 0) {
          console.log(chalk.gray("  📝 暂无持久化记忆。\n"));
        } else {
          console.log(chalk.cyan(`  📝 持久化记忆 (${memories.length} 条):`));
          for (const m of memories) {
            const typeLabel = { user: "👤", feedback: "💬", project: "📁", reference: "📖" }[m.type] || "📌";
            console.log(chalk.gray(`     ${typeLabel} ${m.name} — ${m.description}`));
          }
          console.log("");
        }
        ask();
        return;
      }

      // 删除持久化记忆: /forget <name>
      if (trimmed.toLowerCase().startsWith("/forget ")) {
        const name = trimmed.slice(8).trim();
        if (deleteMemory(name)) {
          console.log(chalk.yellow(`  🗑️ 已删除记忆: ${name}\n`));
        } else {
          console.log(chalk.red(`  ❌ 未找到记忆: ${name}\n`));
        }
        ask();
        return;
      }

      // 手动保存记忆: /remember <name> | <type> | <description> | <content>
      if (trimmed.toLowerCase().startsWith("/remember ")) {
        const input = trimmed.slice(10).trim();
        // 让 Agent 处理保存逻辑，更智能
        console.log(chalk.gray("  保存记忆中..."));
        try {
          const result = await runAgent(
            `用户想保存一条记忆，信息如下（请用 save_memory 工具保存）："${input}"`,
            conversationHistory
          );
          conversationHistory = result.history;
          console.log(chalk.green("\n🤖 Agent:\n"), result.answer, "\n");
        } catch (err: any) {
          console.error(chalk.red(`\n❌ 出错: ${err.message || err}\n`));
        }
        ask();
        return;
      }

      if (
        trimmed.toLowerCase() === "exit" ||
        trimmed.toLowerCase() === "quit"
      ) {
        console.log(chalk.gray("\n👋 再见！\n"));
        rl.close();
        return;
      }

      try {
        const historyHint =
          conversationHistory.length > 0
            ? chalk.gray(` (记忆: ${Math.floor(conversationHistory.length / 2)} 轮对话)`)
            : "";
        console.log(chalk.gray(`  思考中...${historyHint}`));

        // 🧠 传入历史消息，让 Agent 记住之前的一切
        const result = await runAgent(trimmed, conversationHistory);

        // 更新历史
        conversationHistory = result.history;

        console.log(chalk.blue("\n🤖 Agent:\n"), result.answer, "\n");
      } catch (err: any) {
        console.error(chalk.red(`\n❌ 出错: ${err.message || err}\n`));
      }

      ask(); // 循环等待下一次输入
    });
  };

  ask();
}

main();
