// 에이전트 타입을 카테고리·Supertonic voice로 변환하는 라우터
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_VOICE_MAP_PATH = join(__dirname, "..", "voice-map.json");

export interface VoiceMap {
  supertonic: { port: number; lang: string };
  voices: Record<string, string>;
  categories: Record<string, string[]>;
}

const FALLBACK_MAP: VoiceMap = {
  supertonic: { port: 7788, lang: "ko" },
  voices: { default: "F1" },
  categories: {},
};

export function loadVoiceMap(path?: string): VoiceMap {
  const target = path ?? DEFAULT_VOICE_MAP_PATH;
  if (!existsSync(target)) return { ...FALLBACK_MAP };
  try {
    return JSON.parse(readFileSync(target, "utf-8")) as VoiceMap;
  } catch {
    return { ...FALLBACK_MAP };
  }
}

export function resolveVoice(agentType: string, map: VoiceMap): string {
  for (const [category, agents] of Object.entries(map.categories)) {
    if (agents.includes(agentType)) {
      return map.voices[category] ?? map.voices.default ?? "F1";
    }
  }
  return map.voices.default ?? "F1";
}
