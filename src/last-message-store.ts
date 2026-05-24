// 마지막 TTS 재생 텍스트 저장 및 읽기 — /replay 기능 지원
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";

function getDataDir(): string {
  return process.env.VOICE_PERSONA_DATA_DIR ?? join(homedir(), ".local", "share", "voice-persona");
}

function getLastMsgFile(): string {
  return join(getDataDir(), "last-message.txt");
}

function ensureDir(): void {
  const dir = getDataDir();
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

export function saveLastMessage(text: string): void {
  try {
    ensureDir();
    writeFileSync(getLastMsgFile(), text, "utf-8");
  } catch { /* silent fail */ }
}

export function loadLastMessage(): string | null {
  try {
    const file = getLastMsgFile();
    if (!existsSync(file)) return null;
    return readFileSync(file, "utf-8");
  } catch {
    return null;
  }
}
