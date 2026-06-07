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
 */

import * as child_process from "child_process";
import * as os from "os";

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
      if (!caption || caption.includes(":")) {
        // 继续
      } else if (!caption) {
        continue;
      }

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
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const size = bytes / Math.pow(1024, i);
  return `${size.toFixed(2)} ${units[i]}`;
}

// ── JSON-RPC 处理 ─────────────────────────

function handleRequest(request: JsonRpcRequest): Record<string, unknown> {
  const { id, method, params } = request;

  switch (method) {
    case "initialize":
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: {
            tools: {},
          },
          serverInfo: {
            name: "disk-usage",
            version: "1.0.0",
          },
        },
      };

    case "tools/list":
      return {
        jsonrpc: "2.0",
        id,
        result: {
          tools: [
            {
              name: "get_disk_usage",
              description:
                "查询本机所有磁盘分区的占用情况，返回每个磁盘的容量、已用空间、剩余空间、使用率等信息。" +
                "不需要任何参数。适用于用户询问「磁盘还剩多少空间」「哪个盘满了」等问题。",
              inputSchema: {
                type: "object",
                properties: {},
                required: [],
              },
            },
          ],
        },
      };

    case "tools/call": {
      const toolName = params.name as string;
      const toolArgs = params.arguments as Record<string, unknown> || {};

      if (toolName === "get_disk_usage") {
        const disks = getDiskUsage();
        const formatted = disks.map((d) => ({
          盘符: d.mount,
          卷标: d.volumeName || "—",
          文件系统: d.filesystem || "—",
          总容量: formatBytes(d.total),
          已用: formatBytes(d.used),
          剩余: formatBytes(d.free),
          使用率: `${d.usedPercent}%`,
        }));

        const total = disks.reduce((s, d) => s + d.total, 0);
        const totalUsed = disks.reduce((s, d) => s + d.used, 0);
        const totalFree = disks.reduce((s, d) => s + d.free, 0);

        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [
              {
                type: "text",
                text: JSON.stringify(
                  {
                    磁盘列表: formatted,
                    汇总: {
                      总容量: formatBytes(total),
                      已用: formatBytes(totalUsed),
                      剩余: formatBytes(totalFree),
                      总使用率: total > 0 ? `${Math.round((totalUsed / total) * 10000) / 100}%` : "N/A",
                    },
                  },
                  null,
                  2
                ),
              },
            ],
            isError: false,
          },
        };
      }

      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: JSON.stringify({ error: `未知工具: ${toolName}` }) }],
          isError: true,
        },
      };
    }

    default:
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32601, message: `未知方法: ${method}` },
      };
  }
}

// ── 主循环 ────────────────────────────────

let buffer = "";

process.stdin.setEncoding("utf-8");
process.stdin.on("data", (data: string) => {
  buffer += data;

  // 按换行符分割消息（NDJSON）
  const lines = buffer.split("\n");
  buffer = lines.pop() || "";

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    try {
      const request: JsonRpcRequest = JSON.parse(trimmed);
      // 跳过通知
      if (request.id === undefined || request.method === undefined) continue;

      const response = handleRequest(request);
      process.stdout.write(JSON.stringify(response) + "\n");
    } catch (err: any) {
      // JSON 解析错误
      const errorResponse = {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: `解析错误: ${err.message}` },
      };
      process.stdout.write(JSON.stringify(errorResponse) + "\n");
    }
  }
});

// 进程退出处理
process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));

// 启动日志
console.error(`[disk-usage-server] 已启动 (platform: ${os.platform()})`);
