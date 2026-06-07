/**
 * 通用表格格式化工具
 *
 * 解决中英文混排时 Markdown 表格对不齐的问题。
 * 支持 Unicode 框线（默认）、ASCII 框线和 Markdown 三种风格。
 *
 * 核心思路：计算每个字符的"显示宽度"（CJK 字符 = 2，ASCII = 1），
 * 然后精确填充到目标宽度，确保各列严格对齐。
 */

// ── 框线字符集 ──────────────────────────────

interface BoxChars {
  topLeft: string;
  top: string;
  topMid: string;
  topRight: string;
  midLeft: string;
  mid: string;
  midMid: string;
  midRight: string;
  bottomLeft: string;
  bottom: string;
  bottomMid: string;
  bottomRight: string;
  left: string;
  midRow: string;
  right: string;
  horizontal: string;
  vertical: string;
}

const UNICODE_BOX: BoxChars = {
  topLeft: "┌",
  top: "─",
  topMid: "┬",
  topRight: "┐",
  midLeft: "├",
  mid: "─",
  midMid: "┼",
  midRight: "┤",
  bottomLeft: "└",
  bottom: "─",
  bottomMid: "┴",
  bottomRight: "┘",
  left: "│",
  midRow: "│",
  right: "│",
  horizontal: "─",
  vertical: "│",
};

const ASCII_BOX: BoxChars = {
  topLeft: "+",
  top: "-",
  topMid: "+",
  topRight: "+",
  midLeft: "+",
  mid: "-",
  midMid: "+",
  midRight: "+",
  bottomLeft: "+",
  bottom: "-",
  bottomMid: "+",
  bottomRight: "+",
  left: "|",
  midRow: "|",
  right: "|",
  horizontal: "-",
  vertical: "|",
};

// ── 显示宽度计算 ────────────────────────────

/**
 * 判断是否为 CJK 字符（包括中文、日文、韩文等），
 * 这些字符在等宽字体下通常占 2 个英文字符宽度。
 */
function isCJK(char: string): boolean {
  const code = char.codePointAt(0);
  if (code === undefined) return false;
  return (
    (code >= 0x1100 && code <= 0x115f) || // Hangul Jamo
    (code >= 0x2329 && code <= 0x232a) || // 左右尖括号
    (code >= 0x2e80 && code <= 0x303e) || // CJK 部首、标点
    (code >= 0x3040 && code <= 0x33bf) || // 日文假名、CJK
    (code >= 0x3400 && code <= 0x4dbf) || // CJK 扩展 A
    (code >= 0x4e00 && code <= 0xa4cf) || // CJK 统一表意文字
    (code >= 0xa960 && code <= 0xa97c) || // Hangul
    (code >= 0xac00 && code <= 0xd7fb) || // Hangul 音节
    (code >= 0xf900 && code <= 0xfaff) || // CJK 兼容
    (code >= 0xfe10 && code <= 0xfe19) || // 竖排标点
    (code >= 0xfe30 && code <= 0xfe6f) || // CJK 兼容标点
    (code >= 0xff01 && code <= 0xff60) || // 全角 ASCII
    (code >= 0xffe0 && code <= 0xffe6) || // 全角符号
    (code >= 0x1f300 && code <= 0x1f64f) || // Emoji 表情
    (code >= 0x1f680 && code <= 0x1f6ff) || // Emoji 交通
    (code >= 0x20000 && code <= 0x2ffff) // CJK 扩展 B+
  );
}

/**
 * 计算字符串在等宽字体下的"显示宽度"。
 * CJK/全角字符算 2，ASCII 字符算 1。
 */
export function displayWidth(str: string): number {
  let width = 0;
  for (const char of str) {
    width += isCJK(char) ? 2 : 1;
  }
  return width;
}

/**
 * 将字符串填充到指定的显示宽度。
 */
function padToWidth(
  str: string,
  targetWidth: number,
  align: "left" | "center" | "right" = "left"
): string {
  const currentWidth = displayWidth(str);
  const diff = targetWidth - currentWidth;

  if (diff <= 0) return str;

  const padLeft = align === "right" ? diff : align === "center" ? Math.floor(diff / 2) : 0;
  const padRight = align === "left" ? diff : align === "center" ? Math.ceil(diff / 2) : 0;

  return " ".repeat(padLeft) + str + " ".repeat(padRight);
}

// ── 表格格式化 ──────────────────────────────

export type TableStyle = "unicode" | "ascii" | "markdown";

export interface TableColumn {
  header: string;
  align?: "left" | "center" | "right";
}

/**
 * 将数据格式化为对齐的表格字符串。
 *
 * @param columns - 列定义（表头 + 对齐方式）
 * @param rows - 数据行，每行是一个字符串数组
 * @param style - 框线风格，默认 "unicode"
 */
export function formatTable(
  columns: TableColumn[],
  rows: string[][],
  style: TableStyle = "unicode"
): string {
  if (columns.length === 0) return "";
  if (style === "markdown") return formatMarkdownTable(columns, rows);

  const box = style === "ascii" ? ASCII_BOX : UNICODE_BOX;

  // 计算每列最大显示宽度（表头 vs 数据）
  const colWidths: number[] = columns.map((col, i) => {
    let max = displayWidth(col.header);
    for (const row of rows) {
      const w = displayWidth(row[i] ?? "");
      if (w > max) max = w;
    }
    return max;
  });

  // 列间距（左右各 1 空格）
  const padding = 1 + 1; // 左右各一个空格

  // 构建各行
  const lines: string[] = [];

  // 顶部框线
  lines.push(
    box.topLeft +
      colWidths
        .map((w, i) => box.top.repeat(w + padding) + (i < colWidths.length - 1 ? box.topMid : ""))
        .join("") +
      box.topRight
  );

  // 表头行
  lines.push(
    box.left +
      columns
        .map((col, i) =>
          " " + padToWidth(col.header, colWidths[i], col.align ?? "left") + " "
        )
        .join(box.vertical) +
      box.right
  );

  // 表头分隔线
  lines.push(
    box.midLeft +
      colWidths
        .map((w, i) => box.mid.repeat(w + padding) + (i < colWidths.length - 1 ? box.midMid : ""))
        .join("") +
      box.midRight
  );

  // 数据行
  for (const row of rows) {
    lines.push(
      box.left +
        row
          .map((cell, i) =>
            " " + padToWidth(cell, colWidths[i], columns[i]?.align ?? "left") + " "
          )
          .join(box.vertical) +
        box.right
    );
  }

  // 底部框线
  lines.push(
    box.bottomLeft +
      colWidths
        .map((w, i) =>
          box.bottom.repeat(w + padding) + (i < colWidths.length - 1 ? box.bottomMid : "")
        )
        .join("") +
      box.bottomRight
  );

  return lines.join("\n");
}

/**
 * Markdown 表格格式（保持与标准 Markdown 兼容）。
 * 注意：Markdown 表格在 CJK 混排时可能不对齐，这是渲染器的问题。
 */
function formatMarkdownTable(columns: TableColumn[], rows: string[][]): string {
  const lines: string[] = [];

  // 表头
  lines.push("| " + columns.map((c) => c.header).join(" | ") + " |");

  // 分隔行
  lines.push(
    "| " +
      columns
        .map((c) => {
          const align = c.align ?? "left";
          if (align === "center") return ":---:";
          if (align === "right") return "---:";
          return "---";
        })
        .join(" | ") +
      " |"
  );

  // 数据行
  for (const row of rows) {
    lines.push("| " + row.join(" | ") + " |");
  }

  return lines.join("\n");
}

/**
 * 快速使用：用对象数组生成表格。
 * 自动从对象中提取列值，列顺序由 columns 定义。
 */
export function formatTableFromObjects<T extends Record<string, string>>(
  columns: TableColumn[],
  data: T[],
  style: TableStyle = "unicode"
): string {
  const rows = data.map((item) => columns.map((col) => item[col.header] ?? ""));
  return formatTable(columns, rows, style);
}
