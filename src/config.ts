// 사용자 설정 파일 로더 및 기본값 관리
import { readFileSync, existsSync } from "fs";

export interface SirenConfig {
  autoSpeak: boolean;
  minChars: number;
  voice: string;
  summaryModel: string;
  ttsModel: string;
  language: string;
  ttsSpeed: number;
}

const DEFAULTS: SirenConfig = {
  autoSpeak: true,
  minChars: 200,
  voice: "Sohee",
  summaryModel: "gpt-5.4",
  ttsModel: "tts-1",
  language: "ko",
  ttsSpeed: 1.2,
};

export function loadConfig(path?: string): SirenConfig {
  const target = path ?? new URL(".siren.json", import.meta.url).pathname;
  if (!existsSync(target)) return { ...DEFAULTS };
  try {
    return { ...DEFAULTS, ...JSON.parse(readFileSync(target, "utf-8")) };
  } catch {
    return { ...DEFAULTS };
  }
}
