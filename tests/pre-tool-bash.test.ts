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
  classifyPreToolBash,
  handlePreToolBash,
} from "../src/hook-handlers.js";

const BASE_CONFIG = { autoSpeak: true, voice: "Sohee", ttsSpeed: 1.2 } as const;

beforeEach(() => vi.clearAllMocks());

// ── classifyPreToolBash (순수 분류 로직) ──────────────────────

describe("classifyPreToolBash — 파괴적 명령 경고", () => {
  it("rm -rf 명령 → '주의:' 포함 문자열 반환", () => {
    const msg = classifyPreToolBash("rm -rf ./dist");
    expect(msg).toContain("주의:");
  });

  it("git reset --hard 명령 → '주의:' 포함 문자열 반환", () => {
    const msg = classifyPreToolBash("git reset --hard HEAD~1");
    expect(msg).toContain("주의:");
  });

  it("DROP TABLE 명령 → '주의:' 포함 문자열 반환", () => {
    const msg = classifyPreToolBash("psql -c 'DROP TABLE users'");
    expect(msg).toContain("주의:");
  });
});

describe("classifyPreToolBash — 빌드 명령", () => {
  it("npm run build → '빌드를 시작합니다.' 반환", () => {
    expect(classifyPreToolBash("npm run build")).toBe("빌드를 시작합니다.");
  });

  it("tsc --noEmit → '빌드를 시작합니다.' 반환", () => {
    expect(classifyPreToolBash("tsc --noEmit")).toBe("빌드를 시작합니다.");
  });
});

describe("classifyPreToolBash — 테스트 명령", () => {
  it("npm test → '테스트를 실행합니다.' 반환", () => {
    expect(classifyPreToolBash("npm test")).toBe("테스트를 실행합니다.");
  });

  it("npx vitest run → '테스트를 실행합니다.' 반환", () => {
    expect(classifyPreToolBash("npx vitest run")).toBe("테스트를 실행합니다.");
  });

  it("pytest → '테스트를 실행합니다.' 반환", () => {
    expect(classifyPreToolBash("pytest tests/")).toBe("테스트를 실행합니다.");
  });
});

describe("classifyPreToolBash — 패키지 설치 명령", () => {
  it("npm install → '패키지를 설치합니다.' 반환", () => {
    expect(classifyPreToolBash("npm install lodash")).toBe("패키지를 설치합니다.");
  });

  it("pip install → '패키지를 설치합니다.' 반환", () => {
    expect(classifyPreToolBash("pip install requests")).toBe("패키지를 설치합니다.");
  });
});

describe("classifyPreToolBash — 무해한 명령 (발화 없음)", () => {
  it("git status → null 반환", () => {
    expect(classifyPreToolBash("git status")).toBeNull();
  });

  it("ls -la → null 반환", () => {
    expect(classifyPreToolBash("ls -la")).toBeNull();
  });

  it("cat README.md → null 반환", () => {
    expect(classifyPreToolBash("cat README.md")).toBeNull();
  });

  it("echo hello → null 반환", () => {
    expect(classifyPreToolBash("echo hello")).toBeNull();
  });
});

// ── handlePreToolBash (speakHook 연동 테스트) ──────────────────

describe("handlePreToolBash — speakHook 호출 여부", () => {
  it("npm run build 명령 → speakHook('빌드를 시작합니다.') 호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "npm run build" } });
    await handlePreToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).toHaveBeenCalledWith("빌드를 시작합니다.", "Sohee", 1.2);
  });

  it("npm test 명령 → speakHook('테스트를 실행합니다.') 호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "npm test" } });
    await handlePreToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).toHaveBeenCalledWith("테스트를 실행합니다.", "Sohee", 1.2);
  });

  it("rm -rf 명령 → speakHook('주의:') 포함 호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "rm -rf ./node_modules" } });
    await handlePreToolBash(raw, BASE_CONFIG);
    const calledWith = vi.mocked(player.speakHook).mock.calls[0]?.[0] ?? "";
    expect(calledWith).toContain("주의:");
  });

  it("git status 명령 → speakHook 미호출 (무해한 명령)", async () => {
    const raw = JSON.stringify({ tool_input: { command: "git status" } });
    await handlePreToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});

describe("handlePreToolBash — autoSpeak=false", () => {
  it("autoSpeak=false → speakHook 미호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "npm run build" } });
    await handlePreToolBash(raw, { ...BASE_CONFIG, autoSpeak: false });
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});

describe("handlePreToolBash — JSON 파싱 실패", () => {
  it("유효하지 않은 JSON → throw 발생 (호출부에서 catch)", async () => {
    await expect(handlePreToolBash("INVALID_JSON", BASE_CONFIG)).rejects.toThrow();
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});

describe("handlePreToolBash — command 없음", () => {
  it("tool_input.command 누락 → speakHook 미호출", async () => {
    const raw = JSON.stringify({ tool_input: {} });
    await handlePreToolBash(raw, BASE_CONFIG);
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});
