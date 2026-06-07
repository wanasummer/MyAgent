/**
 * 磁盘占用 MCP Server
 *
 * 提供 get_disk_usage 工具，查询本地磁盘的容量、已用空间、剩余空间。
 *
 * 这是一个独立的 MCP Server 进程，通过 stdio (JSON-RPC 2.0) 与 MyAgent 通信。
 * 用法：node dist/mcp/servers/disk-usage-server.js
 *
 * 平台支持：
 *   - Windows: 使用 wmic 命令
 *   - macOS/Linux: 使用 df 命令
 *
 * 🆕 表格格式化：使用 formatTable() 直接生成 Unicode 框线表格，
 *   确保中英文混排时严格对齐。LLM 只需透传结果，无需二次格式化。
 */

import * as child_process from "child_process";
import * as os from "os";
import { formatTable, type TableColumn } from "../../utils/table-formatter.js";

// ── 类型定义 ──────────────────────────────

interface DiskInfo {
  mount: string;        // 盘符/挂载点
  volumeName?: string;  // 卷标 (Windows)
  total: number;        // 总容量 (bytes)
  used: number;         // 已用 (bytes)
  free: number;         // 剩余 (bytes)
  usedPercent: number;  // 使用率
  filesystem?: string;  // 文件系统类型
}

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params: Record<string, unknown>;
}

// ── 磁盘查询实现 ──────────────────────────

/** 查询所有磁盘占用信息 */
function getDiskUsage(): DiskInfo[] {
  if (os.platform() === "win32") {
    return getDiskUsageWindows();
  }
  return getDiskUsageUnix();
}

/** Windows: 使用 wmic 查询逻辑磁盘 */
function getDiskUsageWindows(): DiskInfo[] {
  try {
    const output = child_process.execSync(
      'wmic logicaldisk get size,freespace,caption,volumename /format:csv',
      { encoding: "utf-8", timeout: 10_000 }
    );

    const disks: DiskInfo[] = [];
    const lines = output.trim().split("\n");

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      // 跳过标题行
      if (trimmed.startsWith("Node,")) continue;

      const parts = trimmed.split(",");
      // 格式: Node,Caption,FreeSpace,Size,VolumeName
      if (parts.length < 5) continue;

      const caption = parts[1]?.trim();
      const freeSpace = parseInt(parts[2]?.trim() || "0", 10);
      const size = parseInt(parts[3]?.trim() || "0", 10);
      const volumeName = parts[4]?.trim();

      // 跳过无效盘符
      if (!caption) continue;
      if (!caption.includes(":")) continue;

      if (size <= 0) continue;

      const used = size - freeSpace;
      const usedPercent = size > 0 ? Math.round((used / size) * 10000) / 100 : 0;

      disks.push({
        mount: caption.endsWith(":") ? caption : caption + ":",
        volumeName: volumeName && volumeName !== "" ? volumeName : undefined,
        total: size,
        used,
        free: freeSpace,
        usedPercent,
      });
    }

    return disks;
  } catch (err: any) {
    return [{ mount: "错误", total: 0, used: 0, free: 0, usedPercent: 0, volumeName: `查询失败: ${err.message}` }];
  }
}

/** macOS/Linux: 使用 df 命令 */
function getDiskUsageUnix(): DiskInfo[] {
  try {
    const output = child_process.execSync(
      "df -B1 / /home 2>/dev/null || df -B1 /",
      { encoding: "utf-8", timeout: 10_000 }
    );

    const disks: DiskInfo[] = [];
    const lines = output.trim().split("\n");

    for (let i = 1; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;

      const parts = line.split(/\s+/);
      if (parts.length < 6) continue;

      const filesystem = parts[0];
      const total = parseInt(parts[1], 10);
      const used = parseInt(parts[2], 10);
      const free = parseInt(parts[3], 10);
      const mount = parts[5];

      if (isNaN(total) || total <= 0) continue;

      const usedPercent = Math.round((used / total) * 10000) / 100;

      disks.push({
        mount,
        filesystem,
        total,
        used,
        free,
        usedPercent,
      });
    }

    return disks;
  } catch (err: any) {
    return [{ mount: "错误", total: 0, used: 0, free: 0, usedPercent: 0, volumeName: `查询失败: ${err.message}` }];
  }
}

/** 格式化字节为人类可读 */
function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(
    Math.floor(Math.log(Math.abs(bytes)) / Math.log(1024)),
    units.length - 1
  );
  const value = bytes / Math.pow(1024, i);
  return value.toFixed(2) + " " + units[i];
}

// ── JSON-RPC 请求处理 ─────────────────────

/**
 * 处理 JSON-RPC 请求。
 *
 * 🆕 get_disk_usage 现在返回预格式化的 Unicode 框线表格，
 *   LLM 只需原样展示，无需再自己拼表格。
 */
function handleRequest(request: JsonRpcRequest): Record<string, unknown> {
  const { id, method, params } = request;

  switch (method) {
    // ── 握手 ──────────────────────────────
    case "initialize":
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: {
            name: "disk-usage",
            version: "1.1.0",
          },
        },
      };

    // ── 工具列表 ──────────────────────────
    case "tools/list":
      return {
        jsonrpc: "2.0",
        id,
        result: {
          tools: [
            {
              name: "get_disk_usage",
              description:
                "查询本机所有磁盘分区的占用情况，返回预格式化的 Unicode 框线表格（已对齐，直接展示即可）。",
              inputSchema: {
                type: "object",
                properties: {},
              },
            },
          ],
        },
      };

    // ── 工具调用 ──────────────────────────
    case "tools/call": {
      const toolName = params?.name as string;

      if (toolName === "get_disk_usage") {
        return handleGetDiskUsage(id);
      }

      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: `未知工具: ${toolName}` }],
          isError: true,
        },
      };
    }

    // ── 初始化完成通知（无需响应）─────────
    case "notifications/initialized":
      return { jsonrpc: "2.0", id };

    default:
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32601, message: `未知方法: ${method}` },
      };
  }
}

/**
 * 处理 get_disk_usage 工具调用。
 * 使用 table-formatter 生成完美对齐的 Unicode 框线表格。
 */
function handleGetDiskUsage(id: number): Record<string, unknown> {
  const disks = getDiskUsage();

  // 列定义
  const columns: TableColumn[] = [
    { header: "盘符", align: "left" },
    { header: "卷标", align: "left" },
    { header: "总容量", align: "right" },
    { header: "已用", align: "right" },
    { header: "剩余", align: "right" },
    { header: "使用率", align: "right" },
  ];

  // 数据行
  const rows: string[][] = disks.map((d) => [
    d.mount,
    d.volumeName || (d.filesystem ? d.filesystem : "—"),
    formatBytes(d.total),
    formatBytes(d.used),
    formatBytes(d.free),
    d.usedPercent.toFixed(2) + "%",
  ]);

  // 汇总行
  if (disks.length > 1 && disks[0].mount !== "错误") {
    const total = disks.reduce((s, d) => s + d.total, 0);
    const totalUsed = disks.reduce((s, d) => s + d.used, 0);
    const totalFree = disks.reduce((s, d) => s + d.free, 0);
    const totalPercent =
      total > 0 ? ((totalUsed / total) * 100).toFixed(2) + "%" : "0%";

    rows.push([
      "合计",
      "",
      formatBytes(total),
      formatBytes(totalUsed),
      formatBytes(totalFree),
      totalPercent,
    ]);
  }

  // 🎯 使用 formatTable 生成完美对齐的 Unicode 框线表格
  const tableText = formatTable(columns, rows, "unicode");

  return {
    jsonrpc: "2.0",
    id,
    result: {
      content: [
        {
          type: "text",
          text: tableText,
        },
      ],
    },
  };
}

// ── 主入口 ────────────────────────────────

/**
 * MCP stdio 主循环。
 * 从 stdin 读取 JSON-RPC 请求，处理后写入 stdout。
 * 使用换行分隔的 JSON (NDJSON) 协议。
 */
function main() {
  const stdin = process.stdin;
  const stdout = process.stdout;

  let buffer = "";

  stdin.setEncoding("utf-8");
  stdin.on("data", (chunk: string) => {
    buffer += chunk;

    // 按换行分割，一次可能收到多条消息
    const lines = buffer.split("\n");
    // 最后一行可能不完整，保留到下次
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const request: JsonRpcRequest = JSON.parse(trimmed);
        const response = handleRequest(request);

        // 只有带 id 的请求才需要响应（通知类不需要）
        if (request.id !== undefined && request.id !== null) {
          stdout.write(JSON.stringify(response) + "\n");
        }
      } catch (err: any) {
        stdout.write(
          JSON.stringify({
            jsonrpc: "2.0",
            id: null,
            error: { code: -32700, message: `解析错误: ${err.message}` },
          }) + "\n"
        );
      }
    }
  });

  stdin.on("end", () => {
    // stdin 关闭，正常退出
    process.exit(0);
  });
}

main();
