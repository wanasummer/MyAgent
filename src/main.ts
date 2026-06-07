#!/usr/bin/env node

/**
 * MyAgent — 本地文件管理 & 自我迭代助手
 *
 * 输入人话 → Agent ReAct 循环 → 调用工具操作文件 → 返回中文结果
 * 🧠 RAG 记忆系统 — 本地 TF-IDF 向量检索
 * 🔄 自我迭代 — 可读取和修改自己的源代码
 *
 * 用法:
 *   myagent                 （全局安装后）
 *   npx ts-node src/main.ts （开发时）
 *
 * 配置优先级:
 *   1. ~/.myagent/config
 *   2. 当前目录 .env
 *   3. 系统环境变量
 *
 * 🛡️ 所有路径动态获取，不硬编码，跨平台兼容。
 */

import * as path from "node:path";
import * as os from "node:os";
import * as fs from "node:fs";
import * as readline from "node:readline";
import dotenv from "dotenv";
import chalk from "chalk";
import { runAgent } from "./agent/agent-loop";
import {
  initMemoryDir,
  loadMemories,
  deleteMemory,
  rebuildRagIndex,
  searchMemories,
} from "./memory/memory-store";

// ── 目录迁移：旧版 ~/.myagent 文件 → ~/.myagent/config ──
const MYAGENT_DIR = path.join(os.homedir(), ".myagent");
const MYAGENT_CONFIG = path.join(MYAGENT_DIR, "config");
const OLD_CONFIG = path.join(os.homedir(), ".myagent");

if (fs.existsSync(OLD_CONFIG) && fs.statSync(OLD_CONFIG).isFile()) {
  if (!fs.existsSync(MYAGENT_DIR)) {
    fs.mkdirSync(MYAGENT_DIR, { recursive: true });
  }
  const content = fs.readFileSync(OLD_CONFIG, "utf-8");
  fs.writeFileSync(MYAGENT_CONFIG, content, "utf-8");
  fs.unlinkSync(OLD_CONFIG);
}

// ── 多层级加载 env ──────────────────────────
dotenv.config();
dotenv.config({ path: MYAGENT_CONFIG, override: true });

async function main() {
  // ── 环境检查 ──────────────────────────────
  if (!process.env.DEEPSEEK_API_KEY) {
    console.error(chalk.red("❌ 未设置 DEEPSEEK_API_KEY"));
    console.error(
      chalk.gray(
        "   方式一（推荐）: echo DEEPSEEK_API_KEY=你的key > %USERPROFILE%\\.myagent\\config"
      )
    );
    console.error(chalk.gray("   方式二: 在当前目录创建 .env 文件"));
    console.error(chalk.gray("   方式三: setx DEEPSEEK_API_KEY 你的key"));
    process.exit(1);
  }

  // 🧠 初始化持久化记忆目录 + RAG 索引
  initMemoryDir();

  // 首次启动：如果已有记忆但无向量索引，自动重建
  const existingMemories = loadMemories();
  const vectorsFile = path.join(
    os.homedir(),
    ".myagent",
    "memory",
    "vectors.json"
  );
  if (existingMemories.length > 0 && !fs.existsSync(vectorsFile)) {
    console.log(chalk.gray("  🔄 首次启动，正在构建 RAG 向量索引..."));
    const result = rebuildRagIndex();
    console.log(
      chalk.gray(
        `  ✅ RAG 索引已就绪 (${result.embedded}/${result.total} 条记忆)\n`
      )
    );
  }

  // 调试信息
  const key = process.env.DEEPSEEK_API_KEY || "";
  const masked =
    key.length > 12 ? key.slice(0, 8) + "****" + key.slice(-4) : "****";
  console.log(chalk.gray(`  🔑 Key: ${masked} (长度: ${key.length})`));
  console.log(chalk.gray(`  🌐 API: ${process.env.DEEPSEEK_BASE_URL || "默认"}`));
  console.log(chalk.gray(`  🤖 模型: ${process.env.DEEPSEEK_MODEL || "默认"}`));

  // ── CLI ──────────────────────────────────
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  console.log(chalk.cyan.bold("\n🤖 MyAgent — 自我迭代助手"));
  console.log(chalk.gray("   用自然语言操作文件、管理记忆、迭代自身代码。"));
  console.log(
    chalk.gray("   🧠 RAG 记忆: ~/.myagent/memory/ (本地 TF-IDF 语义检索)")
  );
  console.log(
    chalk.gray(
      "   命令: /memories | /search <关键词> | /rag-rebuild | /forget <name> | clear | exit"
    )
  );
  console.log("");

  let conversationHistory: Array<{ role: string; content: unknown }> = [];

  const ask = () => {
    rl.question(chalk.green("👤 你: "), async (input) => {
      const trimmed = input.trim();
      if (trimmed === "") {
        ask();
        return;
      }

      // ── 特殊命令 ──────────────────────────
      if (trimmed.toLowerCase() === "clear") {
        conversationHistory = [];
        console.log(chalk.yellow("  🧹 对话记忆已清除。\n"));
        ask();
        return;
      }

      if (
        trimmed.toLowerCase() === "exit" ||
        trimmed.toLowerCase() === "quit"
      ) {
        console.log(chalk.gray("  👋 再见！\n"));
        rl.close();
        process.exit(0);
      }

      if (trimmed.toLowerCase() === "/memories") {
        const mems = loadMemories();
        if (mems.length === 0) {
          console.log(chalk.gray("  📝 暂无持久化记忆。\n"));
        } else {
          console.log(chalk.cyan(`  📝 持久化记忆 (${mems.length} 条):`));
          for (const m of mems) {
            console.log(
              chalk.gray(
                `    - ${m.name} [${m.type}]: ${m.description}`
              )
            );
          }
          console.log("");
        }
        ask();
        return;
      }

      if (trimmed.toLowerCase().startsWith("/search ")) {
        const keyword = trimmed.slice(8).trim();
        if (!keyword) {
          console.log(chalk.gray("  用法: /search <关键词>\n"));
          ask();
          return;
        }
        const results = searchMemories(keyword, 5);
        if (!results || results.trim() === "") {
          console.log(chalk.gray(`  🔍 未找到与「${keyword}」相关的记忆。\n`));
        } else {
          console.log(chalk.cyan(`  🔍 RAG 检索结果:\n${results}\n`));
        }
        ask();
        return;
      }

      if (trimmed.toLowerCase().startsWith("/forget ")) {
        const name = trimmed.slice(8).trim();
        if (!name) {
          console.log(chalk.gray("  用法: /forget <记忆名称>\n"));
          ask();
          return;
        }
        const deleted = deleteMemory(name);
        if (deleted) {
          console.log(chalk.yellow(`  🗑️ 已删除记忆: ${name}\n`));
        } else {
          console.log(chalk.red(`  ❌ 未找到记忆: ${name}\n`));
        }
        ask();
        return;
      }

      if (trimmed.toLowerCase() === "/rag-rebuild") {
        console.log(chalk.gray("  🔄 正在重建 RAG 向量索引..."));
        const result = rebuildRagIndex();
        console.log(
          chalk.gray(
            `  ✅ RAG 索引重建完成 (${result.embedded}/${result.total} 条记忆)\n`
          )
        );
        ask();
        return;
      }

      // ── 正常对话 ──────────────────────────
      try {
        const result = await runAgent(trimmed, conversationHistory);
        if (result.answer) {
          // 🎨 只在标签上使用背景色，回答正文不带背景色，避免 ANSI 换行渲染异常
          console.log(chalk.bgCyan.black(`\n🤖 Agent:`) + ` ${result.answer}\n`);
        }
        conversationHistory = result.history;
      } catch (err: any) {
        console.error(chalk.red(`  ❌ 出错了: ${err.message}`));
      }

      ask();
    });
  };

  ask();
}

main().catch((err) => {
  console.error(chalk.red("FATAL:"), err);
  process.exit(2);
});
