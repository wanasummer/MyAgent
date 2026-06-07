#!/usr/bin/env node

/**
 * MyAgent — 本地文件管理 & 分析助手
 *
 * 输入人话 → Agent 自动拆解步骤 → 调用工具操作文件 → 返回中文结果
 * 支持交互式对话模式。
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
import * as readline from "node:readline";
import dotenv from "dotenv";
import chalk from "chalk";
import { runAgent } from "./agent/agent-loop";

// ── 多层级加载 env ──────────────────────────
// 优先级：~/.myagent > CWD/.env > 系统环境变量
// 注意：先加载项目级，再用全局文件强制覆盖，确保 ~/.myagent 始终生效
dotenv.config();                                               // 1. 当前目录 .env
dotenv.config({ path: path.join(os.homedir(), ".myagent"), override: true });  // 2. 全局 ~/.myagent（强制覆盖）

async function main() {
  // ── 环境检查 ──────────────────────────────
  if (!process.env.DEEPSEEK_API_KEY) {
    console.error(chalk.red("❌ 未设置 DEEPSEEK_API_KEY"));
    console.error(chalk.gray("   方式一（推荐）: echo DEEPSEEK_API_KEY=你的key > %USERPROFILE%\\.myagent"));
    console.error(chalk.gray("   方式二: 在当前目录创建 .env 文件"));
    console.error(chalk.gray("   方式三: setx DEEPSEEK_API_KEY 你的key"));
    process.exit(1);
  }

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
  console.log(chalk.gray('   输入 "exit" 或 "quit" 退出。\n'));

  const ask = () => {
    rl.question(chalk.green("👤 你: "), async (input) => {
      const trimmed = input.trim();

      if (trimmed === "") {
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
        console.log(chalk.gray("  思考中..."));
        const result = await runAgent(trimmed);
        console.log(chalk.blue("\n🤖 Agent:\n"), result, "\n");
      } catch (err: any) {
        console.error(chalk.red(`\n❌ 出错: ${err.message || err}\n`));
      }

      ask(); // 循环等待下一次输入
    });
  };

  ask();
}

main();
