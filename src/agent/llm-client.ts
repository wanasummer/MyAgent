/**
 * DeepSeek Anthropic 兼容 API 客户端。
 * 用裸 fetch 而非 SDK，以便灵活控制认证头。
 */

const BASE_URL =
  process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com/anthropic";
const MODEL = process.env.DEEPSEEK_MODEL || "deepseek-v4-pro";

interface ChatParams {
  system: string;
  messages: unknown[];
  tools: unknown[];
}

export async function chatWithTools(params: ChatParams) {
  const apiKey = process.env.DEEPSEEK_API_KEY || "";
  const baseUrl = process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com/anthropic";

  // 调试：确认发送时 key 没被篡改
  if (process.env.DEBUG) {
    console.error(`  [DEBUG] 发送请求到: ${baseUrl}/v1/messages`);
    console.error(`  [DEBUG] Key 前9位: ${apiKey.slice(0, 9)}... 后4位: ${apiKey.slice(-4)}`);
    console.error(`  [DEBUG] Key 长度: ${apiKey.length}`);
  }

  const response = await fetch(`${baseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: MODEL,
      system: params.system,
      messages: params.messages,
      tools: params.tools,
      max_tokens: 4096,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`${response.status} ${errText}`);
  }

  return response.json() as Promise<{
    id: string;
    model: string;
    stop_reason: string;
    content: Array<{
      type: string;
      text?: string;
      id?: string;
      name?: string;
      input?: Record<string, unknown>;
    }>;
  }>;
}
