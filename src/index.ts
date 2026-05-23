// MCP 서버 진입점 — tool 등록 및 hook CLI 분기
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { loadConfig, SirenConfig } from "./config.js";
import { extractSummary } from "./summarizer.js";
import { speak } from "./player.js";

let config: SirenConfig = loadConfig();

// ── hook CLI 모드 ──────────────────────────────────────────
// 사용 예: node dist/index.js hook "읽을 텍스트"
if (process.argv[2] === "hook") {
  const text = process.argv.slice(3).join(" ");
  if (text.length >= config.minChars) {
    const summary = await extractSummary(text, config.summaryModel);
    await speak(summary, config.voice).catch(() => {}); // silent fail
  }
  process.exit(0);
}

// ── MCP 서버 모드 ──────────────────────────────────────────
const server = new Server(
  { name: "siren-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "speak_text",
      description: "전달한 텍스트를 그대로 음성으로 재생합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          text: { type: "string", description: "읽을 텍스트" },
        },
        required: ["text"],
      },
    },
    {
      name: "summarize_and_speak",
      description: "텍스트에서 핵심 문장을 추출해 음성으로 재생합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          text: { type: "string", description: "요약할 텍스트" },
        },
        required: ["text"],
      },
    },
    {
      name: "set_config",
      description: "siren-mcp 설정을 런타임에 변경합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          autoSpeak: { type: "boolean" },
          minChars: { type: "number" },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  try {
    if (name === "speak_text") {
      await speak(String(args?.text ?? ""), config.voice);
      return { content: [{ type: "text" as const, text: "재생 완료" }] };
    }
    if (name === "summarize_and_speak") {
      const text = String(args?.text ?? "");
      const summary = await extractSummary(text, config.summaryModel);
      await speak(summary, config.voice);
      return { content: [{ type: "text" as const, text: `요약 재생: ${summary}` }] };
    }
    if (name === "set_config") {
      config = { ...config, ...(args as Partial<SirenConfig>) };
      return { content: [{ type: "text" as const, text: "설정 변경 완료" }] };
    }
    throw new Error(`알 수 없는 tool: ${name}`);
  } catch (err) {
    // TTS 실패는 silent fail
    const msg = err instanceof Error ? err.message : String(err);
    return { content: [{ type: "text" as const, text: `오류 (무시됨): ${msg}` }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
