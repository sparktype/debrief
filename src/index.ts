// MCP 서버 진입점 — tool 등록 및 hook CLI 분기
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync, existsSync } from "fs";
import { loadConfig, VoicePersonaConfig } from "./config.js";
import { extractSummary, extractOneLiner } from "./summarizer.js";
import { speak, speakAgent, speakHook, configureTimes } from "./player.js";
import { recommendSkill, readRecentTranscripts, saveCooldown } from "./skill-recommender.js";
import { loadLastMessage } from "./last-message-store.js";
import { handlePostToolBash, handlePreToolBash, handleNotification } from "./hook-handlers.js";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { version } = require("../package.json") as { version: string };

let config: VoicePersonaConfig = loadConfig();
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

// Claude Code transcript.jsonl에서 마지막 어시스턴트 텍스트 메시지 추출
function extractLastAssistantText(transcriptPath: string): string {
  try {
    if (!existsSync(transcriptPath)) return "";
    const lines = readFileSync(transcriptPath, "utf-8").split("\n").filter(Boolean).reverse();
    for (const line of lines) {
      const entry = JSON.parse(line) as Record<string, unknown>;
      const msg = (entry.message ?? entry) as Record<string, unknown>;
      if (msg.role !== "assistant") continue;
      const content = msg.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          const b = block as Record<string, unknown>;
          if (b.type === "text" && typeof b.text === "string" && b.text.length >= 20) {
            return b.text;
          }
        }
      }
    }
  } catch { /* 무시 */ }
  return "";
}

// CLAUDE_CODE_SESSION_ID + CLAUDE_PROJECT_DIR → transcript.jsonl 경로 파생
function deriveTranscriptPath(): string {
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID ?? "";
  const projectDir = process.env.CLAUDE_PROJECT_DIR ?? "";
  if (!sessionId || !projectDir) return "";
  const slug = projectDir.replace(/\//g, "-");  // /Users/... → -Users-...
  const claudeDir = process.env.HOME ? `${process.env.HOME}/.claude` : "";
  if (!claudeDir) return "";
  return `${claudeDir}/projects/${slug}/${sessionId}.jsonl`;
}

// transcript.jsonl에서 가장 최근 Agent 툴 호출의 subagent_type 추출
function extractAgentTypeFromTranscript(path: string): string {
  try {
    if (!existsSync(path)) return "";
    const lines = readFileSync(path, "utf-8").split("\n").filter(Boolean).reverse();
    for (const line of lines) {
      const entry = JSON.parse(line) as Record<string, unknown>;
      const content = entry.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (
            typeof block === "object" && block !== null &&
            (block as Record<string, unknown>).type === "tool_use" &&
            (block as Record<string, unknown>).name === "Agent"
          ) {
            const input = (block as Record<string, unknown>).input as Record<string, unknown>;
            const t = input?.subagent_type as string;
            if (t) return t;
          }
        }
      }
    }
  } catch { /* 무시 */ }
  return "";
}

// ── hook CLI 모드 ──────────────────────────────────────────
// Stop hook은 stdin을 보내지 않으므로 transcript에서 직접 읽음
if (process.argv[2] === "hook") {
  const raw = await readStdin();
  let text = "";
  try {
    const data = JSON.parse(raw) as Record<string, unknown>;
    text = (data.last_assistant_message as string) ?? "";
  } catch { /* 무시 */ }
  // stdin에 텍스트가 없으면 transcript에서 마지막 어시스턴트 메시지 추출
  if (!text) {
    const transcriptPath = deriveTranscriptPath();
    if (transcriptPath) text = extractLastAssistantText(transcriptPath);
  }
  if (config.autoSpeak && text.length >= config.minChars) {
    const summary = await extractSummary(text, config.summaryModel);
    await speakHook(summary, config.voice, config.ttsSpeed).catch(() => {});
  }
  process.exit(0);
}

if (process.argv[2] === "subagent-stop") {
  const raw = await readStdin();
  let text = raw;
  let agentType = process.argv[3] ?? "";
  try {
    const data = JSON.parse(raw) as Record<string, unknown>;
    text = (data.last_assistant_message as string) ?? raw;
    if (!agentType) {
      const transcriptPath = (data.transcript_path as string) ?? "";
      if (transcriptPath) agentType = extractAgentTypeFromTranscript(transcriptPath);
    }
  } catch { /* raw 텍스트면 그대로 */ }
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
  const raw = await readStdin();
  let promptHint = "";
  try {
    const data = JSON.parse(raw) as Record<string, unknown>;
    const prompt = (data.prompt as string) ?? "";
    if (prompt.length >= 10) promptHint = `\n[현재 입력]: ${prompt.slice(0, 200)}`;
  } catch {
    // argv[3] fallback (이전 호환)
    promptHint = process.argv[3] ? `\n[현재 입력]: ${String(process.argv[3]).slice(0, 200)}` : "";
  }
  const transcripts = readRecentTranscripts();
  const context = transcripts + promptHint;
  const rec = await recommendSkill(context, false, config.skillCooldownMinutes, config.summaryModel);
  if (rec) {
    const msg = `지금 상황엔 ${rec.skill} 스킬이 유용할 것 같아요`;
    await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
    saveCooldown(rec.skill);
  }
  process.exit(0);
}

if (process.argv[2] === "post-tool-bash") {
  const raw = await readStdin();
  try { await handlePostToolBash(raw, config); } catch { /* JSON 파싱 실패 시 무시 */ }
  process.exit(0);
}

if (process.argv[2] === "pre-tool-bash") {
  const raw = await readStdin();
  try { await handlePreToolBash(raw, config); } catch { /* JSON 파싱 실패 시 무시 */ }
  process.exit(0);
}

if (process.argv[2] === "notification") {
  const raw = await readStdin();
  try { await handleNotification(raw, config); } catch { /* JSON 파싱 실패 시 무시 */ }
  process.exit(0);
}

// ── MCP 서버 모드 ──────────────────────────────────────────
const server = new Server(
  { name: "voice-persona", version },
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
      description: "voice-persona 설정을 런타임에 변경합니다.",
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
      const ALLOWED_CONFIG_KEYS: (keyof VoicePersonaConfig)[] = ["autoSpeak", "minChars", "ttsInstruct"];
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
