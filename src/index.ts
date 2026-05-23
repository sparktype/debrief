// MCP 서버 진입점 — tool 등록 및 hook CLI 분기
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { loadConfig, SirenConfig } from "./config.js";
import { extractSummary, extractOneLiner } from "./summarizer.js";
import { speak, speakAgent, speakHook, configureTimes } from "./player.js";
import { recommendSkill, readRecentTranscripts, saveCooldown } from "./skill-recommender.js";
import { loadLastMessage } from "./last-message-store.js";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { version } = require("../package.json") as { version: string };

let config: SirenConfig = loadConfig();
configureTimes(config.edgeTimeoutMs, config.supertonicTimeoutMs);

// stdin 전체를 읽어 문자열로 반환 — Command Injection 방지용 텍스트 수신 헬퍼
async function readStdin(): Promise<string> {
  return new Promise((resolve) => {
    // TTY(터미널 직접 실행)면 stdin 대기 없이 빈 문자열 반환
    if (process.stdin.isTTY) {
      resolve("");
      return;
    }
    const chunks: Buffer[] = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8").trim()));
    process.stdin.on("error", () => resolve(""));
  });
}

// ── hook CLI 모드 ──────────────────────────────────────────
// 사용 예: printf '%s' "$TEXT" | node dist/index.js hook
if (process.argv[2] === "hook") {
  const text = await readStdin();
  if (config.autoSpeak && text.length >= config.minChars) {
    const summary = await extractSummary(text, config.summaryModel);
    // EdgeTTS(HyunsuMultilingualNeural) → 스풀 큐 → 데몬 순차 재생
    await speakHook(summary, config.voice, config.ttsSpeed).catch(() => {});
  }
  process.exit(0);
}

if (process.argv[2] === "subagent-stop") {
  // TEXT: stdin으로 수신, AGENT_TYPE: argv[3] (특수문자 없는 타입명)
  const text = await readStdin();
  const agentType = process.argv[3] ?? "";
  if (text.length >= config.minChars) {
    const { loadVoiceMap, resolveVoice, getAgentLabel } = await import("./voice-router.js");
    const voiceMap = loadVoiceMap();
    const voice = resolveVoice(agentType, voiceMap);
    const label = getAgentLabel(agentType, voiceMap);
    const oneLiner = await extractOneLiner(text, config.summaryModel);
    const announcement = `${label}입니다. ${oneLiner}`;
    await speakAgent(announcement, voice, config.supertonicPort, config.ttsSpeed).catch(() => {});
  }
  process.exit(0);
}

if (process.argv[2] === "hook-suggest") {
  const context = process.argv[3] ?? readRecentTranscripts();
  const rec = await recommendSkill(context, false, config.skillCooldownMinutes, config.summaryModel);
  if (rec) {
    const msg = `지금 상황엔 ${rec.skill} 스킬이 유용할 것 같아요`;
    await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
    saveCooldown(rec.skill);
  }
  process.exit(0);
}

// ── MCP 서버 모드 ──────────────────────────────────────────
const server = new Server(
  { name: "summary-voice-mcp", version },
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
      description: "summary-voice-mcp 설정을 런타임에 변경합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          autoSpeak: { type: "boolean" },
          minChars: { type: "number" },
          ttsInstruct: { type: "string" },
        },
      },
    },
    {
      name: "suggest_skill",
      description: "현재 transcript를 분석해 유용한 스킬 1개를 음성으로 추천합니다. 쿨다운을 무시하고 강제 추천합니다.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "speak_last",
      description: "마지막으로 재생한 TTS 텍스트를 다시 읽어줍니다.",
      inputSchema: { type: "object" as const, properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  try {
    if (name === "speak_text") {
      await speak(String(args?.text ?? ""), config.voice, config.ttsSpeed, config.ttsInstruct);
      return { content: [{ type: "text" as const, text: "재생 완료" }] };
    }
    if (name === "summarize_and_speak") {
      const text = String(args?.text ?? "");
      const summary = await extractSummary(text, config.summaryModel);
      await speak(summary, config.voice, config.ttsSpeed, config.ttsInstruct);
      return { content: [{ type: "text" as const, text: `요약 재생: ${summary}` }] };
    }
    if (name === "set_config") {
      const ALLOWED_CONFIG_KEYS: (keyof SirenConfig)[] = ["autoSpeak", "minChars", "ttsInstruct"];
      const patch = Object.fromEntries(
        ALLOWED_CONFIG_KEYS
          .filter(k => k in (args ?? {}))
          .map(k => [k, (args as any)[k]])
      );
      config = { ...config, ...patch };
      return { content: [{ type: "text" as const, text: "설정 변경 완료" }] };
    }
    if (name === "suggest_skill") {
      const context = readRecentTranscripts();
      const rec = await recommendSkill(context, true, config.skillCooldownMinutes);
      if (rec) {
        const msg = `지금 상황엔 ${rec.skill} 스킬이 유용할 것 같아요`;
        await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
        saveCooldown(rec.skill);
        return { content: [{ type: "text" as const, text: `추천: ${rec.skill}` }] };
      }
      return { content: [{ type: "text" as const, text: "추천할 스킬을 찾지 못했습니다" }] };
    }
    if (name === "speak_last") {
      const last = loadLastMessage();
      if (!last) {
        const msg = "재생할 내용이 없어요";
        await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
        return { content: [{ type: "text" as const, text: msg }] };
      }
      await speak(last, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
      return { content: [{ type: "text" as const, text: "재생 완료" }] };
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
