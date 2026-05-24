import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// speakHook 모킹 — 실제 TTS 호출 없음
vi.mock("../src/player.js", () => ({
  speakHook: vi.fn().mockResolvedValue(undefined),
  speak: vi.fn().mockResolvedValue(undefined),
  speakAgent: vi.fn().mockResolvedValue(undefined),
  configureTimes: vi.fn(),
}));

import * as player from "../src/player.js";
import {
  classifyPostToolBash,
  handlePostToolBash,
} from "../src/hook-handlers.js";

const BASE_CONFIG = { autoSpeak: true, voice: "Sohee", ttsSpeed: 1.2 } as const;

beforeEach(() => vi.clearAllMocks());

// ── classifyPostToolBash (순수 분류 로직) ─────────────────────

describe("classifyPostToolBash — 빌드 명령", () => {
  it("npm run build exitCode=0 → '빌드 완료.' 반환", () => {
    expect(classifyPostToolBash("npm run build", "", 0)).toBe("빌드 완료.");
  });

  it("npm run build exitCode=1 → '빌드 실패.' 포함 문자열 반환", () => {
    const msg = classifyPostToolBash("npm run build", "", 1);
    expect(msg).toContain("빌드 실패");
  });

  it("tsc 명령 exitCode=0 → '빌드 완료.' 반환", () => {
    expect(classifyPostToolBash("tsc --noEmit", "", 0)).toBe("빌드 완료.");
  });

  it("tsc 명령 exitCode=1 → '빌드 실패.' 포함 반환", () => {
    const msg = classifyPostToolBash("tsc", "", 1);
    expect(msg).toContain("빌드 실패");
  });
});

describe("classifyPostToolBash — 테스트 명령", () => {
  it("npm test output='3 passed' exitCode=0 → '전체 3개 통과.' 반환", () => {
    expect(classifyPostToolBash("npm test", "3 passed", 0)).toBe("전체 3개 통과.");
  });

  it("npm test output='2 failed, 5 passed' exitCode=1 → '테스트 2개 실패, 5개 통과.' 반환", () => {
    const msg = classifyPostToolBash("npm test", "2 failed, 5 passed", 1);
    expect(msg).toBe("테스트 2개 실패, 5개 통과.");
  });

  it("npm test output='1 failing' exitCode=1 → '테스트 1개 실패' 포함 반환", () => {
    const msg = classifyPostToolBash("npm test", "1 failing", 1);
    expect(msg).toContain("테스트 1개 실패");
  });

  it("vitest 명령 output='7 passed' exitCode=0 → '전체 7개 통과.' 반환", () => {
    expect(classifyPostToolBash("npx vitest run", "7 passed", 0)).toBe("전체 7개 통과.");
  });

  it("npm test output에 passed/failed 없으면 null 반환", () => {
    expect(classifyPostToolBash("npm test", "no results", 0)).toBeNull();
  });
});

describe("classifyPostToolBash — 알 수 없는 명령", () => {
  it("알 수 없는 명령 exitCode=1 → null (빌드/테스트 외는 실패해도 알림 없음)", () => {
    const msg = classifyPostToolBash("some-unknown-cmd --flag", "", 1);
    expect(msg).toBeNull();
  });

  it("알 수 없는 명령 exitCode=0 → null 반환 (성공은 알림 없음)", () => {
    expect(classifyPostToolBash("some-cmd", "", 0)).toBeNull();
  });
});

// ── handlePostToolBash (speakHook 연동 테스트) ─────────────────

describe("handlePostToolBash — speakHook 호출 여부", () => {
  it("npm run build exitCode=0 → speakHook('빌드 완료.') 호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { exitCode: 0, output: "" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).toHaveBeenCalledWith("빌드 완료.", "Sohee", 1.2);
  });

  it("npm run build exitCode=1 → speakHook('빌드 실패.') 포함 호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { exitCode: 1, output: "" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    const calledWith = vi.mocked(player.speakHook).mock.calls[0]?.[0] ?? "";
    expect(calledWith).toContain("빌드 실패");
  });

  it("npm test output='3 passed' exitCode=0 → speakHook('전체 3개 통과.') 호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm test" },
      tool_response: { exitCode: 0, output: "3 passed" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).toHaveBeenCalledWith("전체 3개 통과.", "Sohee", 1.2);
  });

  it("npm test output='2 failed, 5 passed' exitCode=1 → speakHook('테스트 2개 실패, 5개 통과.') 호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm test" },
      tool_response: { exitCode: 1, output: "2 failed, 5 passed" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).toHaveBeenCalledWith("테스트 2개 실패, 5개 통과.", "Sohee", 1.2);
  });

  it("알 수 없는 명령 exitCode=1 → speakHook 미호출 (빌드/테스트 외는 알림 없음)", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "some-tool --flag value" },
      tool_response: { exitCode: 1, output: "" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("exit_code 키(snake_case)도 정상 인식 — exitCode=1과 동일하게 처리", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { exit_code: 1, output: "" },
    });
    await handlePostToolBash(raw, BASE_CONFIG);
    const calledWith = vi.mocked(player.speakHook).mock.calls[0]?.[0] ?? "";
    expect(calledWith).toContain("빌드 실패");
  });
});

describe("handlePostToolBash — autoSpeak=false", () => {
  it("autoSpeak=false → speakHook 미호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { exitCode: 0, output: "" },
    });
    await handlePostToolBash(raw, { ...BASE_CONFIG, autoSpeak: false });
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});

describe("handlePostToolBash — JSON 파싱 실패", () => {
  it("유효하지 않은 JSON → throw 발생 (호출부에서 catch)", async () => {
    await expect(handlePostToolBash("NOT_JSON", BASE_CONFIG)).rejects.toThrow();
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});
