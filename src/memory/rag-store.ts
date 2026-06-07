/**
 * RAG (Retrieval-Augmented Generation) 记忆存储。
 *
 * 将记忆文档分块 → 本地 TF-IDF 向量化 → JSON 向量库 → 余弦相似度检索。
 *
 * 🔑 核心设计决策：使用本地 n-gram + TF-IDF 而非外部 Embedding API
 *   理由：
 *     1. 零外部依赖，零 API 费用
 *     2. 完全离线可用
 *     3. 跨平台（Windows/macOS/Linux）
 *     4. 记忆量小（几十条）时 n-gram TF-IDF 效果足够好
 *
 * 架构：
 *   ~/.myagent/memory/*.md         ← 源记忆文件
 *   ~/.myagent/memory/vectors.json ← TF-IDF 向量索引 + 词汇表
 *
 * 中文处理：使用字符 2-gram + 3-gram 作为特征（无需分词器）。
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { loadMemories, type Memory } from "./memory-store";

// ── 路径 ──────────────────────────────────────
const MEMORY_DIR = path.join(os.homedir(), ".myagent", "memory");
const VECTOR_FILE = path.join(MEMORY_DIR, "vectors.json");

// ── 配置 ──────────────────────────────────────
const NGRAM_SIZES = [2, 3]; // 字符 n-gram 大小

// ── 类型 ──────────────────────────────────────
export interface Chunk {
  memoryName: string;
  index: number;
  text: string;
  /** TF-IDF 向量（稀疏存储：只存非零项） */
  vector: Record<number, number>; // tokenId → tfidf 值
}

export interface VectorStore {
  version: number;
  updatedAt: number;
  /** 全局词汇表：token → tokenId */
  vocabulary: Record<string, number>;
  /** 文档频率：tokenId → 多少文档包含该 token */
  docFrequency: Record<number, number>;
  chunks: Chunk[];
}

export interface SearchResult {
  memoryName: string;
  chunkIndex: number;
  text: string;
  score: number; // 0~1
}

// ── n-gram 分词 ───────────────────────────────

/**
 * 将文本转为字符 n-gram 集合。
 * 支持中英文混合：中文用 2-gram/3-gram，英文保留原词边界。
 */
function tokenize(text: string): string[] {
  const tokens: string[] = [];
  const normalized = text.toLowerCase().replace(/\s+/g, " ");

  for (const n of NGRAM_SIZES) {
    for (let i = 0; i <= normalized.length - n; i++) {
      tokens.push(normalized.slice(i, i + n));
    }
  }

  return tokens;
}

// ── 分块 ──────────────────────────────────────

const CHUNK_SIZE = 500;
const CHUNK_OVERLAP = 100;

function chunkText(
  text: string,
  memoryName: string
): Array<{ memoryName: string; index: number; text: string; tokens: string[] }> {
  const chunks: Array<{
    memoryName: string;
    index: number;
    text: string;
    tokens: string[];
  }> = [];
  const sentences = text.split(/(?<=[。！？\n])\s*/);

  let current = "";
  let index = 0;

  for (const sentence of sentences) {
    if ((current + sentence).length > CHUNK_SIZE && current.length > 0) {
      const trimmed = current.trim();
      chunks.push({
        memoryName,
        index: index++,
        text: trimmed,
        tokens: tokenize(trimmed),
      });
      current = current.slice(-CHUNK_OVERLAP) + sentence;
    } else {
      current += sentence;
    }
  }

  if (current.trim().length > 0) {
    const trimmed = current.trim();
    chunks.push({
      memoryName,
      index,
      text: trimmed,
      tokens: tokenize(trimmed),
    });
  }

  return chunks;
}

// ── TF-IDF 向量化 ─────────────────────────────

/**
 * 构建词频映射：token → 出现次数
 */
function buildTermFreq(tokens: string[]): Record<string, number> {
  const tf: Record<string, number> = {};
  for (const t of tokens) {
    tf[t] = (tf[t] || 0) + 1;
  }
  return tf;
}

/**
 * 对一批分块做 TF-IDF 向量化。
 * 同时更新全局词汇表和文档频率。
 */
function vectorizeChunks(
  rawChunks: Array<{
    memoryName: string;
    index: number;
    text: string;
    tokens: string[];
  }>,
  vocabulary: Record<string, number>,
  docFrequency: Record<number, number>,
  totalDocs: number
): Chunk[] {
  const chunks: Chunk[] = [];

  // 更新词汇表和文档频率
  for (const rc of rawChunks) {
    const tf = buildTermFreq(rc.tokens);
    const seenTokens = new Set<string>();

    for (const [token, count] of Object.entries(tf)) {
      // 分配 token ID
      if (!(token in vocabulary)) {
        vocabulary[token] = Object.keys(vocabulary).length;
      }
      const tokenId = vocabulary[token];

      // 更新文档频率
      if (!seenTokens.has(token)) {
        docFrequency[tokenId] = (docFrequency[tokenId] || 0) + 1;
        seenTokens.add(token);
      }
    }
  }

  // 构建 TF-IDF 向量
  for (const rc of rawChunks) {
    const tf = buildTermFreq(rc.tokens);
    const vector: Record<number, number> = {};
    const docCount = totalDocs + rawChunks.length;

    for (const [token, count] of Object.entries(tf)) {
      const tokenId = vocabulary[token];
      const df = docFrequency[tokenId] || 1;
      const idf = Math.log(docCount / df) + 1; // smooth IDF
      vector[tokenId] = count * idf;
    }

    chunks.push({
      memoryName: rc.memoryName,
      index: rc.index,
      text: rc.text,
      vector,
    });
  }

  return chunks;
}

// ── 向量存储管理 ──────────────────────────────

function loadVectorStore(): VectorStore {
  try {
    if (fs.existsSync(VECTOR_FILE)) {
      const raw = fs.readFileSync(VECTOR_FILE, "utf-8");
      return JSON.parse(raw) as VectorStore;
    }
  } catch {
    // 文件损坏
  }
  return {
    version: 2,
    updatedAt: 0,
    vocabulary: {},
    docFrequency: {},
    chunks: [],
  };
}

function saveVectorStore(store: VectorStore): void {
  if (!fs.existsSync(MEMORY_DIR)) {
    fs.mkdirSync(MEMORY_DIR, { recursive: true });
  }
  store.updatedAt = Date.now();
  fs.writeFileSync(VECTOR_FILE, JSON.stringify(store, null, 2), "utf-8");
}

// ── 余弦相似度 ────────────────────────────────

function cosineSimilarity(
  a: Record<number, number>,
  b: Record<number, number>
): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;

  // 遍历较小的那个向量
  const iter = Object.keys(a).length < Object.keys(b).length ? a : b;
  const other = iter === a ? b : a;

  for (const keyStr of Object.keys(iter)) {
    const key = Number(keyStr);
    const va = a[key] || 0;
    const vb = b[key] || 0;
    dot += va * vb;
  }

  for (const keyStr of Object.keys(a)) {
    const v = a[Number(keyStr)];
    normA += v * v;
  }
  for (const keyStr of Object.keys(b)) {
    const v = b[Number(keyStr)];
    normB += v * v;
  }

  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

// ── 更新单条记忆的向量 ────────────────────────

export function embedMemory(memory: Memory): void {
  const store = loadVectorStore();

  // 移除旧分块
  store.chunks = store.chunks.filter((c) => c.memoryName !== memory.name);

  // 分块
  const rawChunks = chunkText(memory.content, memory.name);
  if (rawChunks.length === 0) return;

  // 向量化
  const totalDocs = store.chunks.length + rawChunks.length || 1;
  const newChunks = vectorizeChunks(
    rawChunks,
    store.vocabulary,
    store.docFrequency,
    totalDocs
  );

  store.chunks.push(...newChunks);
  saveVectorStore(store);
}

// ── 删除记忆向量 ──────────────────────────────

export function forgetVector(memoryName: string): void {
  const store = loadVectorStore();
  store.chunks = store.chunks.filter((c) => c.memoryName !== memoryName);
  saveVectorStore(store);
}

// ── 语义检索 ──────────────────────────────────

/**
 * 根据查询文本，用 TF-IDF + 余弦相似度检索最相关的记忆片段。
 */
export function searchMemories(
  query: string,
  topK: number = 5
): SearchResult[] {
  const store = loadVectorStore();
  if (store.chunks.length === 0) return [];

  // 查询分词 + TF-IDF
  const queryTokens = tokenize(query);
  const queryTf = buildTermFreq(queryTokens);

  const queryVector: Record<number, number> = {};
  const totalDocs = store.chunks.length || 1;

  for (const [token, count] of Object.entries(queryTf)) {
    const tokenId = store.vocabulary[token];
    if (tokenId === undefined) continue; // 词不在词汇表中
    const df = store.docFrequency[tokenId] || 1;
    const idf = Math.log(totalDocs / df) + 1;
    queryVector[tokenId] = count * idf;
  }

  // 余弦相似度排序
  const scored: SearchResult[] = store.chunks.map((chunk) => ({
    memoryName: chunk.memoryName,
    chunkIndex: chunk.index,
    text: chunk.text,
    score: cosineSimilarity(queryVector, chunk.vector),
  }));

  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, topK);
}

// ── 全量重建 ──────────────────────────────────

export function rebuildVectorStore(): {
  total: number;
  embedded: number;
} {
  const memories = loadMemories();
  const store: VectorStore = {
    version: 2,
    updatedAt: Date.now(),
    vocabulary: {},
    docFrequency: {},
    chunks: [],
  };

  // 先收集所有原始分块
  const allRawChunks: Array<{
    memoryName: string;
    index: number;
    text: string;
    tokens: string[];
  }> = [];

  for (const memory of memories) {
    const rawChunks = chunkText(memory.content, memory.name);
    allRawChunks.push(...rawChunks);
  }

  if (allRawChunks.length > 0) {
    const newChunks = vectorizeChunks(
      allRawChunks,
      store.vocabulary,
      store.docFrequency,
      0
    );
    store.chunks = newChunks;
  }

  saveVectorStore(store);
  return { total: memories.length, embedded: memories.length };
}

// ── 格式化检索结果 ────────────────────────────

export function formatSearchResults(results: SearchResult[]): string {
  if (results.length === 0) return "";

  const lines: string[] = [
    "## 🔍 RAG 语义检索到的相关记忆",
    "",
  ];

  // 按记忆名称分组
  const grouped: Record<string, SearchResult[]> = {};
  for (const r of results) {
    if (!grouped[r.memoryName]) grouped[r.memoryName] = [];
    grouped[r.memoryName].push(r);
  }

  for (const [name, chunks] of Object.entries(grouped)) {
    const topScore = chunks[0].score;
    lines.push(
      `- **${name}** (相关度: ${(topScore * 100).toFixed(0)}%)`
    );
    for (const c of chunks) {
      const snippet =
        c.text.length > 200 ? c.text.slice(0, 200) + "..." : c.text;
      lines.push(`  > ${snippet}`);
    }
    lines.push("");
  }

  return lines.join("\n");
}
