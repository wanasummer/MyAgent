/**
 * 持久化记忆存储 — 文件 + RAG（本地 TF-IDF）混合模式。
 *
 * ── 文件存储（主） ──
 *   记忆目录: ~/.myagent/memory/
 *   索引文件: ~/.myagent/memory/MEMORY.md
 *   记忆文件: ~/.myagent/memory/{slug}.md  (frontmatter + 内容)
 *
 * ── RAG 向量存储（辅） ──
 *   向量文件: ~/.myagent/memory/vectors.json
 *   本地 n-gram TF-IDF 向量化，零外部依赖。
 *   保存/删除记忆时自动更新向量索引。
 *
 * 🛡️ 路径全部动态获取（os.homedir()），不硬编码桌面路径。
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import {
  embedMemory,
  forgetVector,
  searchMemories as searchMemoriesRag,
  formatSearchResults,
  rebuildVectorStore as rebuildRag,
} from "./rag-store";

// ── 路径（动态获取）───────────────────────────
const MEMORY_DIR = path.join(os.homedir(), ".myagent", "memory");
const INDEX_FILE = path.join(MEMORY_DIR, "MEMORY.md");

// ── 类型 ──────────────────────────────────────
export interface MemoryMeta {
  name: string;
  description: string;
  type: "user" | "feedback" | "project" | "reference";
}

export interface Memory extends MemoryMeta {
  content: string;
  filePath: string;
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
function parseFrontmatter(raw: string): {
  meta: Partial<MemoryMeta>;
  body: string;
} | null {
  const match = raw.match(/^---\s*\n([\s\S]*?)\n---\s*\n([\s\S]*)$/);
  if (!match) return null;

  const yamlBlock = match[1];
  const body = match[2].trim();

  const meta: Partial<MemoryMeta> = {};
  const nameMatch = yamlBlock.match(/^name:\s*(.+)$/m);
  if (nameMatch) meta.name = nameMatch[1].trim();
  const descMatch = yamlBlock.match(/^description:\s*(.+)$/m);
  if (descMatch) meta.description = descMatch[1].trim();
  const typeMatch = yamlBlock.match(/^\s*type:\s*(.+)$/m);
  if (typeMatch) meta.type = typeMatch[1].trim() as MemoryMeta["type"];

  return { meta, body };
}

// ── 重建索引文件 ──────────────────────────────
function rebuildIndex(): void {
  const memories = loadMemories();
  const lines = ["# MyAgent Memory Index", ""];
  for (const m of memories) {
    lines.push(
      `- [${m.name}](${m.name}.md) — ${m.description || "无描述"}`
    );
  }
  lines.push("");
  fs.writeFileSync(INDEX_FILE, lines.join("\n"), "utf-8");
}

// ── 加载所有记忆 ──────────────────────────────
export function loadMemories(): Memory[] {
  initMemoryDir();
  const memories: Memory[] = [];
  try {
    const files = fs.readdirSync(MEMORY_DIR);
    for (const file of files) {
      if (
        file === "MEMORY.md" ||
        file === "vectors.json" ||
        !file.endsWith(".md")
      )
        continue;
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
  } catch {
    // 目录为空
  }
  return memories;
}

// ── 加载索引 ──────────────────────────────────
export function loadMemoryIndex(): string {
  initMemoryDir();
  try {
    return fs.readFileSync(INDEX_FILE, "utf-8");
  } catch {
    return "";
  }
}

// ── 保存记忆（写文件 + 更新 RAG 向量） ────────
export function saveMemory(
  meta: MemoryMeta,
  content: string
): boolean {
  initMemoryDir();
  const fileName = `${meta.name}.md`;
  const filePath = path.join(MEMORY_DIR, fileName);

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
    rebuildIndex();

    // 🔍 RAG: 同步更新向量索引
    embedMemory({
      name: meta.name,
      description: meta.description,
      type: meta.type,
      content,
      filePath,
    });

    return true;
  } catch {
    return false;
  }
}

// ── 删除记忆（删文件 + 清除向量） ────────────
export function deleteMemory(name: string): boolean {
  initMemoryDir();
  const fileName = `${name}.md`;
  const filePath = path.join(MEMORY_DIR, fileName);

  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      rebuildIndex();
      forgetVector(name);
      return true;
    }
    return false;
  } catch {
    return false;
  }
}

// ── 格式化记忆上下文 ──────────────────────────

export function formatMemoryContext(): string {
  const memories = loadMemories();
  if (memories.length === 0) return "";

  const index = loadMemoryIndex();
  const lines = ["## 📝 持久化记忆 (来自 ~/.myagent/memory/)"];

  for (const m of memories) {
    const emoji: Record<string, string> = {
      user: "👤",
      feedback: "💬",
      project: "📁",
      reference: "📖",
    };
    lines.push(
      `- **${m.name}** [${emoji[m.type] || "📖"} ${m.type}]: ${m.description}`
    );
  }

  lines.push("");
  lines.push("**索引文件 MEMORY.md:**");
  lines.push("```");
  lines.push(index.trim());
  lines.push("```");

  return lines.join("\n");
}

// ── 🔍 RAG 语义检索 ──────────────────────────

export function searchMemories(
  query: string,
  topK?: number
): string {
  const results = searchMemoriesRag(query, topK);
  return formatSearchResults(results);
}

// ── 全量重建向量索引 ──────────────────────────

export function rebuildRagIndex(): { total: number; embedded: number } {
  return rebuildRag();
}
