// 에이전트 타입을 카테고리·Supertonic voice로 변환하는 라우터
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_VOICE_MAP_PATH = join(__dirname, "..", "voice-map.json");

export interface VoiceMap {
  supertonic: { lang: string };
  voices: Record<string, string>;
  categories: Record<string, string[]>;
}

const FALLBACK_MAP: VoiceMap = {
  supertonic: { lang: "ko" },
  voices: { default: "F1" },
  categories: {},
};

function isValidVoiceMap(obj: unknown): obj is VoiceMap {
  return (
    typeof obj === "object" && obj !== null &&
    "supertonic" in obj &&
    "voices" in obj && "categories" in obj
  );
}

export function loadVoiceMap(path?: string): VoiceMap {
  const target = path ?? DEFAULT_VOICE_MAP_PATH;
  if (!existsSync(target)) return { ...FALLBACK_MAP };
  try {
    const parsed = JSON.parse(readFileSync(target, "utf-8"));
    if (!isValidVoiceMap(parsed)) return { ...FALLBACK_MAP };
    return parsed;
  } catch {
    return { ...FALLBACK_MAP };
  }
}

const CATEGORY_LABELS: Record<string, string> = {
  reviewer: "리뷰어",
  planner:  "플래너",
  builder:  "빌더",
  tester:   "테스터",
  explorer: "탐색기",
};

export function getAgentLabel(agentType: string, map?: VoiceMap): string {
  const m = map ?? loadVoiceMap();
  for (const [cat, agents] of Object.entries(m.categories)) {
    if (agents.includes(agentType)) {
      return CATEGORY_LABELS[cat] ?? "에이전트";
    }
  }
  return "에이전트";
}

export function resolveVoice(agentType: string, map: VoiceMap): string {
  for (const [category, agents] of Object.entries(map.categories)) {
    if (agents.includes(agentType)) {
      return map.voices[category] ?? map.voices.default ?? "F1";
    }
  }
  return map.voices.default ?? "F1";
}
