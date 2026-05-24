import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const DATA_DIR = join(homedir(), ".local", "share", "voice-persona-test");

import { saveLastMessage, loadLastMessage } from "../src/last-message-store.js";

beforeEach(() => {
  // 테스트 간 환경변수 격리 — afterEach에서 vi.unstubAllEnvs()로 복원
  vi.stubEnv("VOICE_PERSONA_DATA_DIR", DATA_DIR);
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
});

afterEach(() => {
  vi.unstubAllEnvs();
  if (existsSync(DATA_DIR)) rmSync(DATA_DIR, { recursive: true });
});

describe("last-message-store", () => {
  it("저장 후 읽으면 동일 텍스트 반환", () => {
    saveLastMessage("안녕하세요");
    expect(loadLastMessage()).toBe("안녕하세요");
  });

  it("저장 전 읽으면 null 반환", () => {
    expect(loadLastMessage()).toBeNull();
  });

  it("빈 문자열도 저장/읽기 정상 동작", () => {
    saveLastMessage("");
    expect(loadLastMessage()).toBe("");
  });
});
