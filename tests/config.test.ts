import { describe, it, expect, afterEach } from "vitest";
import { writeFileSync, unlinkSync, existsSync } from "fs";
import { loadConfig } from "../src/config.js";

const TMP = "/tmp/test-voice-persona.json";

afterEach(() => { if (existsSync(TMP)) unlinkSync(TMP); });

describe("loadConfig", () => {
  it("파일 없으면 기본값 반환", () => {
    const c = loadConfig("/nonexistent/path.json");
    expect(c.autoSpeak).toBe(true);
    expect(c.minChars).toBe(50);
    expect(c.voice).toBe("Sohee");
    expect(c.ttsSpeed).toBe(1.2);
    expect(c.ttsInstruct).toBe("밝고 활기차게 말해주세요");
    expect(c.summaryModel).toBe("gpt-5.4");
  });

  it("파일 있으면 기본값에 병합", () => {
    writeFileSync(TMP, JSON.stringify({ minChars: 300, voice: "alloy" }));
    const c = loadConfig(TMP);
    expect(c.minChars).toBe(300);
    expect(c.voice).toBe("alloy");
    expect(c.autoSpeak).toBe(true); // 기본값 유지
  });

  it("JSON 파싱 실패 시 기본값 반환", () => {
    writeFileSync(TMP, "not json");
    const c = loadConfig(TMP);
    expect(c.minChars).toBe(50);
  });

  it("skillCooldownMinutes 기본값 30", () => {
    const c = loadConfig("/nonexistent/path.json");
    expect(c.skillCooldownMinutes).toBe(30);
  });

  it("edgeTimeoutMs 기본값 10000", () => {
    const cfg = loadConfig("/nonexistent.json");
    expect(cfg.edgeTimeoutMs).toBe(10000);
  });

  it("supertonicTimeoutMs 기본값 20000", () => {
    const cfg = loadConfig("/nonexistent.json");
    expect(cfg.supertonicTimeoutMs).toBe(20000);
  });
});

describe("VoicePersonaConfig — 미사용 필드 제거", () => {
  it("기본 설정에 ttsModel 없음", () => {
    const c = loadConfig("/nonexistent/should-not-exist.json");
    expect((c as Record<string, unknown>).ttsModel).toBeUndefined();
  });

  it("기본 설정에 language 없음", () => {
    const c = loadConfig("/nonexistent/should-not-exist.json");
    expect((c as Record<string, unknown>).language).toBeUndefined();
  });
});
