/**
 * MCP Client — 通过 stdio 与 MCP Server 通信。
 *
 * 实现 JSON-RPC 2.0 协议，支持：
 *   1. initialize 握手
 *   2. tools/list 获取工具列表
 *   3. tools/call 调用工具
 *
 * 与 MCP Server 通过 child_process.spawn 连接，
 * 使用换行分隔的 JSON (NDJSON) 进行消息交互。
 */

import { spawn, ChildProcess } from "child_process";
import * as path from "path";

// ── 类型定义 ──────────────────────────────

export interface McpToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

interface InitializeResult {
  protocolVersion: string;
  capabilities: Record<string, unknown>;
  serverInfo: { name: string; version: string };
}

interface ToolsListResult {
  tools: McpToolDefinition[];
}

interface ToolsCallResult {
  content: Array<{ type: string; text?: string }>;
  isError?: boolean;
}

// ── MCP Client ────────────────────────────

export class McpClient {
  private process: ChildProcess | null = null;
  private requestId = 0;
  private pending = new Map<
    number,
    { resolve: (v: unknown) => void; reject: (e: Error) => void }
  >();
  private buffer = "";
  private serverName: string;

  constructor(
    private command: string,
    private args: string[],
    private serverKey: string
  ) {
    this.serverName = serverKey;
  }

  /** 启动 MCP Server 并完成握手 */
  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error(`[MCP:${this.serverName}] 连接超时（10秒）`));
      }, 10_000);

      this.process = spawn(this.command, this.args, {
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env },
      });

      // 监听 stderr 用于调试日志
      if (this.process.stderr) {
        this.process.stderr.on("data", (data: Buffer) => {
          const msg = data.toString().trim();
          if (msg) {
            console.log(`  [MCP:${this.serverName}] stderr: ${msg}`);
          }
        });
      }

      // 监听 stdout 获取响应
      if (this.process.stdout) {
        this.process.stdout.on("data", (data: Buffer) => {
          this.buffer += data.toString();
          this.processBuffer();
        });
      }

      this.process.on("error", (err) => {
        clearTimeout(timeout);
        reject(new Error(`[MCP:${this.serverName}] 进程启动失败: ${err.message}`));
      });

      this.process.on("exit", (code) => {
        if (code !== 0 && code !== null) {
          console.log(`  [MCP:${this.serverName}] 进程退出，代码: ${code}`);
        }
      });

      // 执行 MCP 握手
      this.sendRequest("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: {
          name: "myagent",
          version: "1.0.0",
        },
      })
        .then((result) => {
          const initResult = result as InitializeResult;
          console.log(
            `  ✅ [MCP:${this.serverName}] 已连接 ` +
              `(${initResult.serverInfo.name} v${initResult.serverInfo.version}, ` +
              `协议 ${initResult.protocolVersion})`
          );

          // 发送 initialized 通知
          this.sendNotification("notifications/initialized", {});
          clearTimeout(timeout);
          resolve();
        })
        .catch((err) => {
          clearTimeout(timeout);
          reject(err);
        });
    });
  }

  /** 获取该 Server 提供的工具列表 */
  async getTools(): Promise<McpToolDefinition[]> {
    const result = (await this.sendRequest("tools/list", {})) as ToolsListResult;
    return result.tools || [];
  }

  /** 调用工具 */
  async callTool(
    toolName: string,
    args: Record<string, unknown>
  ): Promise<ToolsCallResult> {
    const result = (await this.sendRequest("tools/call", {
      name: toolName,
      arguments: args,
    })) as ToolsCallResult;
    return result;
  }

  /** 断开连接 */
  disconnect(): void {
    if (this.process) {
      this.process.kill();
      this.process = null;
    }
    this.pending.clear();
  }

  // ── 内部方法 ────────────────────────────

  /** 发送 JSON-RPC 请求并等待响应 */
  private async sendRequest(
    method: string,
    params: Record<string, unknown>
  ): Promise<unknown> {
    const id = ++this.requestId;
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method,
      params,
    };

    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });

      const payload = JSON.stringify(request) + "\n";
      if (this.process?.stdin) {
        this.process.stdin.write(payload);
      } else {
        this.pending.delete(id);
        reject(new Error(`[MCP:${this.serverName}] stdin 不可用`));
      }
    });
  }

  /** 发送 JSON-RPC 通知（无需响应） */
  private sendNotification(
    method: string,
    params: Record<string, unknown>
  ): void {
    const notification = {
      jsonrpc: "2.0",
      method,
      params,
    };
    const payload = JSON.stringify(notification) + "\n";
    if (this.process?.stdin) {
      this.process.stdin.write(payload);
    }
  }

  /** 处理缓冲区中的响应消息 */
  private processBuffer(): void {
    const lines = this.buffer.split("\n");
    // 保留最后一个可能不完整的行
    this.buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const response: JsonRpcResponse = JSON.parse(trimmed);

        // 跳过通知（没有 id）
        if (response.id === undefined) continue;

        const pending = this.pending.get(response.id);
        if (!pending) continue;

        this.pending.delete(response.id);

        if (response.error) {
          pending.reject(
            new Error(
              `[MCP:${this.serverName}] 错误 ${response.error.code}: ${response.error.message}`
            )
          );
        } else {
          pending.resolve(response.result);
        }
      } catch {
        // 非 JSON 行，跳过
      }
    }
  }
}

/**
 * 根据 server 脚本路径构造启动命令。
 * 如果是 .ts 文件，用 ts-node 运行；否则用 node 运行。
 */
export function buildServerCommand(
  scriptPath: string
): { command: string; args: string[] } {
  if (scriptPath.endsWith(".ts")) {
    // 尝试用项目本地的 ts-node
    const tsNodePath = path.join(
      process.cwd(),
      "node_modules",
      ".bin",
      process.platform === "win32" ? "ts-node.cmd" : "ts-node"
    );
    return { command: tsNodePath, args: [scriptPath] };
  }
  return { command: "node", args: [scriptPath] };
}
