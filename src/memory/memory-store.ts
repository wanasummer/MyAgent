/**
 * Claude Code 风格持久化记忆存储。
 *
 * 记忆目录: ~/.myagent/memory/
 * 索引文件: ~/.myagent/memory/MEMORY.md  (一行一条记忆概要)
 * 记忆文件: ~/.myagent/memory/{slug}.md  (frontmatter + 内容)
 *
 * Frontmatter 格式:
 *   ---
 *   name: <kebab-case-slug>
 *   description: <one-line summary — used to decide relevance during recall>
 *   metadata:
 *     type: user | feedback | project | reference
 *   ---
 *   <the fact content>
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";

// ── 路径 ──────────────────────────────────────
const MEMORY_DIR = path.join(os.homedir(), ".myagent", "memory");
const INDEX_FILE = path.join(MEMORY_DIR, "MEMORY.md");

// ── 类型 ──────────────────────────────────────
export interface MemoryMeta {
  name: string;        // kebab-case 文件名（不含 .md）
  description: string; // 一行概要，用于判断相关性
  type: "user" | "feedback" | "project" | "reference";
}

export interface Memory extends MemoryMeta {
  content: string;     // frontmatter 之后的正文
  filePath: string;    // 完整路径
}

// ── 初始化 ────────────────────────────────────
export function initMemoryDir(): void {
  if (!fs.existsSync(MEMORY_DIR)) {
    fs.mkdirSync(MEMORY_DIR, { recursive: true });
  }
  if (!fs.existsSync(INDEX_FILE)) {
    fs.writeFileSync(INDEX_FILE, "# MyAgent Memory Index\n\n", "utf-8");
  }
}

// ── 解析 Frontmatter ──────────────────────────
function parseFrontmatter(raw: string): { meta: Partial<MemoryMeta>; body: string } | null {
  const match = raw.match(/^---\s*\n([\s\S]*?)\n---\s*\n([\s\S]*)$/);
  if (!match) return null;

  const yamlBlock = match[1];
  const body = match[2].trim();

  const meta: Partial<MemoryMeta> = {};

  // 简易 YAML 解析（name / description / metadata.type）
  const nameMatch = yamlBlock.match(/^name:\s*(.+)$/m);
  if (nameMatch) meta.name = nameMatch[1].trim();

  const descMatch = yamlBlock.match(/^description:\s*(.+)$/m);
  if (descMatch) meta.description = descMatch[1].trim();

  const typeMatch = yamlBlock.match(/^\s*type:\s*(.+)$/m);
  if (typeMatch) meta.type = typeMatch[1].trim() as MemoryMeta["type"];

  return { meta, body };
}

// ── 加载所有记忆 ──────────────────────────────
export function loadMemories(): Memory[] {
  initMemoryDir();

  const memories: Memory[] = [];

  try {
    const files = fs.readdirSync(MEMORY_DIR);
    for (const file of files) {
      if (file === "MEMORY.md" || !file.endsWith(".md")) continue;

      const filePath = path.join(MEMORY_DIR, file);
      const raw = fs.readFileSync(filePath, "utf-8");
      const parsed = parseFrontmatter(raw);

      if (parsed && parsed.meta.name) {
        memories.push({
          name: parsed.meta.name,
          description: parsed.meta.description || "",
          type: parsed.meta.type || "reference",
          content: parsed.body,
          filePath,
        });
      }
    }
  } catch (err) {
    // 目录为空或无法读取，忽略
  }

  return memories;
}

// ── 加载 MEMORY.md 索引（纯文本）──────────────
export function loadMemoryIndex(): string {
  initMemoryDir();
  try {
    return fs.readFileSync(INDEX_FILE, "utf-8");
  } catch {
    return "";
  }
}

// ── 保存一条记忆 ─────────────────────────────
export function saveMemory(meta: MemoryMeta, content: string): boolean {
  initMemoryDir();

  const fileName = `${meta.name}.md`;
  const filePath = path.join(MEMORY_DIR, fileName);

  // 如果已存在同名文件，追加更新标记
  const frontmatter = [
    "---",
    `name: ${meta.name}`,
    `description: ${meta.description}`,
    "metadata:",
    `  type: ${meta.type}`,
    "---",
    "",
    content,
  ].join("\n");

  try {
    fs.writeFileSync(filePath, frontmatter, "utf-8");

    // 更新索引
    rebuildIndex();
    return true;
  } catch (err) {
    return false;
  }
}

// ── 删除一条记忆 ─────────────────────────────
export function deleteMemory(name: string): boolean {
  const fileName = `${name}.md`;
  const filePath = path.join(MEMORY_DIR, fileName);

  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      rebuildIndex();
      return true;
    }
    return false;
  } catch {
    return false;
  }
}

// ── 重建 MEMORY.md 索引 ──────────────────────
function rebuildIndex(): void {
  const memories = loadMemories();
  const lines = ["# MyAgent Memory Index", ""];

  for (const m of memories) {
    const hook = m.description.length > 60
      ? m.description.slice(0, 57) + "..."
      : m.description;
    lines.push(`- [${m.name}](${m.name}.md) — ${hook}`);
  }

  if (memories.length === 0) {
    lines.push("暂无记忆。");
  }

  fs.writeFileSync(INDEX_FILE, lines.join("\n") + "\n", "utf-8");
}

// ── 格式化为系统提示词上下文 ──────────────────
export function formatMemoryContext(): string {
  const index = loadMemoryIndex();
  const memories = loadMemories();

  if (memories.length === 0) {
    return "当前没有持久化记忆。你可以通过工具保存用户的重要偏好和需求。";
  }

  // 只注入索引到 system prompt（节省 token）
  // 具体内容由 Agent 需要时通过工具读取
  const summary = memories
    .map((m) => `- **${m.name}** [${m.type}]: ${m.description}`)
    .join("\n");

  return [
    "## 📝 持久化记忆 (来自 ~/.myagent/memory/)",
    "",
    "以下是已保存的记忆摘要。你可以用 `recall_memory` 工具读取完整内容。",
    "",
    summary,
    "",
    "**索引文件 MEMORY.md:**",
    "```",
    index.replace(/^#.*$/gm, "").trim() || "(空)",
    "```",
  ].join("\n");
}
