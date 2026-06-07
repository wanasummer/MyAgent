/**
 * MCP Manager — 管理多个 MCP Server 连接。
 *
 * 职责：
 *   1. 启动/停止 MCP Server
 *   2. 聚合所有 MCP 工具定义
 *   3. 路由工具调用到正确的 Server
 *
 * 工具命名规则：mcp__{serverKey}__{toolName}
 * 如：mcp__disk__get_disk_usage
 */

import { McpClient, McpToolDefinition, buildServerCommand } from "./mcp-client";
import * as path from "path";
import * as os from "os";

// ── 类型 ──────────────────────────────────

/** 转为 Anthropic-compatible 的工具定义 */
export interface McpToolDefAnthropic {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

interface ServerConfig {
  /** 唯一标识 */
  key: string;
  /** 启动命令 */
  command: string;
  /** 命令行参数 */
  args: string[];
  /** 描述 */
  description: string;
}

// ── 默认配置 ──────────────────────────────

function getDefaultServers(): ServerConfig[] {
  const projectDir = process.cwd();
  const diskServerPath = path.join(
    projectDir,
    "src",
    "mcp",
    "servers",
    "disk-usage-server.ts"
  );
  const { command, args } = buildServerCommand(diskServerPath);

  return [
    {
      key: "disk",
      command,
      args,
      description: "磁盘占用查询服务",
    },
  ];
}

// ── MCP Manager ───────────────────────────

export class McpManager {
  private clients = new Map<string, McpClient>();
  private tools = new Map<string, McpToolDefAnthropic>();
  private toolRouting = new Map<string, { client: McpClient; toolName: string }>();

  /** 启动所有 MCP Server 并获取工具列表 */
  async initialize(servers?: ServerConfig[]): Promise<void> {
    const configs = servers || getDefaultServers();

    console.log(`🔌 正在连接 ${configs.length} 个 MCP Server...`);

    const results = await Promise.allSettled(
      configs.map((cfg) => this.connectServer(cfg))
    );

    for (let i = 0; i < configs.length; i++) {
      const result = results[i];
      if (result.status === "rejected") {
        console.log(`  ⚠️  [MCP:${configs[i].key}] 连接失败: ${result.reason.message}`);
      }
    }

    console.log(
      `🔧 MCP 工具总数: ${this.tools.size}（来自 ${this.clients.size} 个 Server）`
    );
  }

  /** 获取所有 MCP 工具定义（Anthropic 兼容格式） */
  getAllToolDefs(): McpToolDefAnthropic[] {
    return Array.from(this.tools.values());
  }

  /** 调用 MCP 工具 */
  async callTool(
    fullName: string,
    args: Record<string, unknown>
  ): Promise<unknown> {
    const routing = this.toolRouting.get(fullName);
    if (!routing) {
      return { error: `未知的 MCP 工具: ${fullName}` };
    }

    try {
      const result = await routing.client.callTool(routing.toolName, args);
      return result;
    } catch (err: any) {
      return { error: `MCP 工具调用失败: ${err.message}` };
    }
  }

  /** 停止所有 MCP Server */
  shutdown(): void {
    for (const [key, client] of this.clients) {
      console.log(`  🔌 断开 [MCP:${key}]`);
      client.disconnect();
    }
    this.clients.clear();
    this.tools.clear();
    this.toolRouting.clear();
  }

  // ── 内部方法 ────────────────────────────

  private async connectServer(cfg: ServerConfig): Promise<void> {
    const client = new McpClient(cfg.command, cfg.args, cfg.key);
    await client.connect();
    this.clients.set(cfg.key, client);

    // 获取工具列表并注册
    const tools = await client.getTools();
    for (const tool of tools) {
      const fullName = `mcp__${cfg.key}__${tool.name}`;
      const def: McpToolDefAnthropic = {
        name: fullName,
        description: `[MCP:${cfg.key}] ${tool.description}`,
        input_schema: {
          type: "object",
          properties: tool.inputSchema.properties || {},
          required: tool.inputSchema.required,
        },
      };
      this.tools.set(fullName, def);
      this.toolRouting.set(fullName, { client, toolName: tool.name });
    }

    console.log(
      `  📦 [MCP:${cfg.key}] 注册了 ${tools.length} 个工具: ` +
        tools.map((t) => t.name).join(", ")
    );
  }
}

/** 单例 */
let instance: McpManager | null = null;

export function getMcpManager(): McpManager {
  if (!instance) {
    instance = new McpManager();
  }
  return instance;
}
