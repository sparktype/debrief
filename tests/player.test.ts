import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import * as cp from "child_process";
import * as fs from "fs";
import { EventEmitter } from "events";

vi.mock("child_process", async (importOriginal) => {
  const orig = await importOriginal<typeof cp>();
  return { ...orig, spawn: vi.fn() };
});

vi.mock("fs", async (importOriginal) => {
  const orig = await importOriginal<typeof fs>();
  return { ...orig, existsSync: vi.fn(() => true) };
});

import { speak } from "../src/player.js";

afterEach(() => vi.clearAllMocks());

function mockProc(exitCode: number) {
  const proc = new EventEmitter() as any;
  proc.stderr = new EventEmitter();
  vi.mocked(cp.spawn).mockReturnValue(proc as any);
  setImmediate(() => proc.emit("close", exitCode));
  return proc;
}

// fetch mock 헬퍼: health OK + speak OK
function mockFetchOk() {
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, status: 200 }));
}

// fetch mock 헬퍼: health 실패(연결 거부)
function mockFetchDead() {
  vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("ECONNREFUSED")));
}

// fetch mock 헬퍼: health OK + speak non-2xx
function mockFetchHealthOkSpeakFail() {
  vi.stubGlobal(
    "fetch",
    vi.fn()
      .mockResolvedValueOnce({ ok: true, status: 200 })   // health
      .mockResolvedValueOnce({ ok: false, status: 500 }), // speak
  );
}

describe("speak — HTTP 서버 경로", () => {
  it("서버 응답 200 → fetch만 호출, spawn 없음", async () => {
    mockFetchOk();
    await speak("안녕", "Sohee");
    expect(fetch).toHaveBeenCalledTimes(2); // health + speak
    expect(cp.spawn).not.toHaveBeenCalled();
  });

  it("서버 speak 500 응답 → subprocess 폴백", async () => {
    mockFetchHealthOkSpeakFail();
    vi.mocked(fs.existsSync).mockReturnValue(true);
    mockProc(0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenCalled();
  });

  it("서버 연결 거부(fetch throw) → subprocess 폴백", async () => {
    mockFetchDead();
    vi.mocked(fs.existsSync).mockReturnValue(false);
    mockProc(0);
    await speak("안녕");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });
});

describe("speak — say 경로 (서버 없음, MLX 스피커 아닌 경우)", () => {
  beforeEach(() => {
    // health check 실패 → subprocess 경로
    mockFetchDead();
  });

  it("기본 목소리(시스템) — -v 없이 say 호출", async () => {
    mockProc(0);
    await expect(speak("안녕")).resolves.toBeUndefined();
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });

  it("macOS 목소리 지정 시 -v 옵션 포함", async () => {
    mockProc(0);
    await speak("안녕", "Yuna");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["-v", "Yuna", "안녕"]);
  });

  it("say 실패 시 reject", async () => {
    mockProc(1);
    await expect(speak("안녕")).rejects.toThrow("say 명령 실패");
  });

  it("spawn 오류 시 reject", async () => {
    const proc = new EventEmitter() as any;
    proc.stderr = new EventEmitter();
    vi.mocked(cp.spawn).mockReturnValue(proc as any);
    setImmediate(() => proc.emit("error", new Error("ENOENT")));
    await expect(speak("안녕")).rejects.toThrow("ENOENT");
  });
});

describe("speak — MLX TTS 경로 (서버 없음, Sohee 등)", () => {
  beforeEach(() => {
    mockFetchDead();
  });

  it("Sohee — python3 mlx_audio.tts.generate 호출", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(true);
    mockProc(0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenCalledWith(
      expect.stringContaining("python3"),
      expect.arrayContaining([
        "-m", "mlx_audio.tts.generate",
        "--voice", "Sohee",
        "--play",
      ]),
      expect.any(Object),
    );
  });

  it("MLX TTS 실패 시 reject", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(true);
    mockProc(1);
    await expect(speak("안녕", "Sohee")).rejects.toThrow("MLX TTS 실패");
  });

  it("tts-venv 없으면 say 폴백", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(false);
    mockProc(0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["-v", "Sohee", "안녕"]);
  });
});
