import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  classifyPostToolBash,
  classifyPreToolBash,
  handlePostToolBash,
  handlePreToolBash,
  handleNotification,
} from "../src/hook-handlers.js";

// handlePostToolBash / handlePreToolBash / handleNotification 은 speakHook 호출
vi.mock("../src/player.js", () => ({
  speakHook: vi.fn().mockResolvedValue(undefined),
}));

import * as player from "../src/player.js";

const cfg = { autoSpeak: true, voice: "Sohee", ttsSpeed: 1.2 };

// ── classifyPostToolBash ───────────────────────────────────────
describe("classifyPostToolBash", () => {
  it("빌드 성공 → '빌드 완료.'", () => {
    expect(classifyPostToolBash("npm run build", "", 0)).toBe("빌드 완료.");
  });

  it("빌드 실패 → '빌드 실패. 에러를 확인하세요.'", () => {
    expect(classifyPostToolBash("npm run build", "", 1)).toBe("빌드 실패. 에러를 확인하세요.");
  });

  it("tsc 빌드 성공", () => {
    expect(classifyPostToolBash("tsc --noEmit", "", 0)).toBe("빌드 완료.");
  });

  it("테스트 실패 포함 → 실패 수 언급", () => {
    const out = "3 failed, 10 passed";
    expect(classifyPostToolBash("npm test", out, 1)).toBe("테스트 3개 실패, 10개 통과.");
  });

  it("테스트 전체 통과", () => {
    const out = "15 passed";
    expect(classifyPostToolBash("npx vitest run", out, 0)).toBe("전체 15개 통과.");
  });

  it("테스트 실패만 (통과 없음)", () => {
    const out = "2 failing";
    expect(classifyPostToolBash("pytest", out, 1)).toBe("테스트 2개 실패.");
  });

  it("테스트 커맨드지만 파싱 불가 → null", () => {
    expect(classifyPostToolBash("npm test", "no matches", 0)).toBeNull();
  });

  it("일반 명령 실패 → 명령 앞 3단어 포함", () => {
    const msg = classifyPostToolBash("git push origin main", "", 128);
    expect(msg).toBe("명령 실패: git push origin.");
  });

  it("일반 명령 성공 → null", () => {
    expect(classifyPostToolBash("git status", "", 0)).toBeNull();
  });

  it("go build 지원", () => {
    expect(classifyPostToolBash("go build ./...", "", 0)).toBe("빌드 완료.");
  });

  it("cargo test 지원", () => {
    const out = "5 passed; 0 failed";
    expect(classifyPostToolBash("cargo test", out, 0)).toBe("전체 5개 통과.");
  });
});

// ── classifyPreToolBash ───────────────────────────────────────
describe("classifyPreToolBash", () => {
  it("rm -rf → 경고 메시지", () => {
    expect(classifyPreToolBash("rm -rf dist")).toBe("주의: 되돌릴 수 없는 작업입니다.");
  });

  it("git reset --hard → 경고 메시지", () => {
    expect(classifyPreToolBash("git reset --hard HEAD")).toBe("주의: 되돌릴 수 없는 작업입니다.");
  });

  it("DROP TABLE → 경고 메시지", () => {
    expect(classifyPreToolBash("DROP TABLE users")).toBe("주의: 되돌릴 수 없는 작업입니다.");
  });

  it("npm run build → 빌드 착수", () => {
    expect(classifyPreToolBash("npm run build")).toBe("빌드를 시작합니다.");
  });

  it("tsc → 빌드 착수", () => {
    expect(classifyPreToolBash("tsc --watch")).toBe("빌드를 시작합니다.");
  });

  it("npm test → 테스트 착수", () => {
    expect(classifyPreToolBash("npm test")).toBe("테스트를 실행합니다.");
  });

  it("pytest → 테스트 착수", () => {
    expect(classifyPreToolBash("pytest tests/")).toBe("테스트를 실행합니다.");
  });

  it("npm install → 패키지 설치", () => {
    expect(classifyPreToolBash("npm install express")).toBe("패키지를 설치합니다.");
  });

  it("pip install → 패키지 설치", () => {
    expect(classifyPreToolBash("pip install requests")).toBe("패키지를 설치합니다.");
  });

  it("해당 없는 명령 → null", () => {
    expect(classifyPreToolBash("ls -la")).toBeNull();
  });

  it("빈 명령 → null", () => {
    expect(classifyPreToolBash("")).toBeNull();
  });
});

// ── handlePostToolBash ────────────────────────────────────────
describe("handlePostToolBash", () => {
  beforeEach(() => { vi.mocked(player.speakHook).mockClear(); });

  it("빌드 성공 시 speakHook 호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { output: "", exitCode: 0 },
    });
    await handlePostToolBash(raw, cfg);
    expect(player.speakHook).toHaveBeenCalledWith("빌드 완료.", "Sohee", 1.2);
  });

  it("autoSpeak=false → speakHook 미호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { output: "", exitCode: 0 },
    });
    await handlePostToolBash(raw, { ...cfg, autoSpeak: false });
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("exit_code(snake_case) 필드 지원", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "npm run build" },
      tool_response: { output: "", exit_code: 1 },
    });
    await handlePostToolBash(raw, cfg);
    expect(player.speakHook).toHaveBeenCalledWith("빌드 실패. 에러를 확인하세요.", "Sohee", 1.2);
  });

  it("분류 결과 null이면 speakHook 미호출", async () => {
    const raw = JSON.stringify({
      tool_input: { command: "git status" },
      tool_response: { output: "", exitCode: 0 },
    });
    await handlePostToolBash(raw, cfg);
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("JSON 파싱 실패 시 throw (index.ts에서 catch)", async () => {
    await expect(handlePostToolBash("not-json", cfg)).rejects.toThrow();
  });
});

// ── handlePreToolBash ─────────────────────────────────────────
describe("handlePreToolBash", () => {
  beforeEach(() => { vi.mocked(player.speakHook).mockClear(); });

  it("rm -rf 경고 speakHook 호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "rm -rf node_modules" } });
    await handlePreToolBash(raw, cfg);
    expect(player.speakHook).toHaveBeenCalledWith("주의: 되돌릴 수 없는 작업입니다.", "Sohee", 1.2);
  });

  it("autoSpeak=false → speakHook 미호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "npm run build" } });
    await handlePreToolBash(raw, { ...cfg, autoSpeak: false });
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("일반 명령 → null이므로 speakHook 미호출", async () => {
    const raw = JSON.stringify({ tool_input: { command: "cat package.json" } });
    await handlePreToolBash(raw, cfg);
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("command 필드 없으면 speakHook 미호출", async () => {
    const raw = JSON.stringify({ tool_input: {} });
    await handlePreToolBash(raw, cfg);
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});

// ── handleNotification ────────────────────────────────────────
describe("handleNotification", () => {
  beforeEach(() => { vi.mocked(player.speakHook).mockClear(); });

  it("message 필드 우선 사용", async () => {
    const raw = JSON.stringify({ title: "제목", message: "본문 알림" });
    await handleNotification(raw, cfg);
    expect(player.speakHook).toHaveBeenCalledWith("본문 알림", "Sohee", 1.2);
  });

  it("message 없으면 title 사용", async () => {
    const raw = JSON.stringify({ title: "제목만" });
    await handleNotification(raw, cfg);
    expect(player.speakHook).toHaveBeenCalledWith("제목만", "Sohee", 1.2);
  });

  it("autoSpeak=false → speakHook 미호출", async () => {
    const raw = JSON.stringify({ message: "알림" });
    await handleNotification(raw, { ...cfg, autoSpeak: false });
    expect(player.speakHook).not.toHaveBeenCalled();
  });

  it("빈 메시지 → speakHook 미호출", async () => {
    const raw = JSON.stringify({});
    await handleNotification(raw, cfg);
    expect(player.speakHook).not.toHaveBeenCalled();
  });
});
