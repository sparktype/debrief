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
  return { ...orig, existsSync: vi.fn(() => true), unlinkSync: vi.fn(), writeFileSync: vi.fn() };
});

vi.mock("../src/last-message-store.js", () => ({
  saveLastMessage: vi.fn(),
}));
import * as store from "../src/last-message-store.js";

import { speak, speakAgent } from "../src/player.js";
const { existsSync, unlinkSync, writeFileSync } = fs;

// proc.on("close") 등록 시점에 lazily 이벤트를 발생 — 타이밍 경합 방지
function makeOnceProc(exitCode: number): any {
  const proc = new EventEmitter() as any;
  proc.stderr = new EventEmitter();
  const origOn = proc.on.bind(proc);
  proc.on = (event: string, listener: any) => {
    origOn(event, listener);
    if (event === "close") setImmediate(() => proc.emit("close", exitCode));
    return proc;
  };
  return proc;
}

// 여러 spawn 호출을 순서대로 mock (mockReturnValueOnce 큐)
function mockSpawnSequence(...exitCodes: number[]) {
  exitCodes.forEach((code) => {
    vi.mocked(cp.spawn).mockReturnValueOnce(makeOnceProc(code) as any);
  });
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

// mockReturnValueOnce 큐까지 완전 초기화
beforeEach(() => { vi.mocked(fs.existsSync).mockReturnValue(true); });
afterEach(() => vi.resetAllMocks());

describe("speak — EdgeTTS 경로 (온라인 우선)", () => {
  beforeEach(() => {
    vi.mocked(fs.existsSync).mockReturnValue(true); // tts-venv 존재
    vi.stubGlobal("fetch", vi.fn()); // 호출 감시용 (성공 케이스에서는 호출 없어야 함)
  });

  it("EdgeTTS 성공 → python3 + afplay 두 번 spawn, fetch 미호출", async () => {
    mockSpawnSequence(0, 0); // python3 exit 0, afplay exit 0
    await speak("안녕", "Sohee");
    expect(fetch).not.toHaveBeenCalled();
    expect(cp.spawn).toHaveBeenCalledTimes(2);
  });

  it("Sohee voice → ko-KR-HyunsuMultilingualNeural 로 python3 호출", async () => {
    mockSpawnSequence(0, 0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining("python3"),
      expect.arrayContaining(["ko-KR-HyunsuMultilingualNeural"]),
    );
  });

  it("instruct 파라미터는 EdgeTTS에 전달되지 않음", async () => {
    mockSpawnSequence(0, 0);
    await speak("안녕", "Sohee", 1.2, "빠르게 말해주세요");
    const [, args] = vi.mocked(cp.spawn).mock.calls[0];
    expect(args).not.toContain("빠르게 말해주세요");
  });

  it("EdgeTTS 실패(exit 1) → HTTP 폴백 시도", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, status: 200 }));
    mockSpawnSequence(1); // python3 fail
    await speak("안녕", "Sohee");
    expect(fetch).toHaveBeenCalled();
  });

  it("tts-venv 없으면 EdgeTTS 건너뜀 → HTTP 폴백", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(false);
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, status: 200 }));
    await speak("안녕", "Sohee");
    expect(cp.spawn).not.toHaveBeenCalled();
    expect(fetch).toHaveBeenCalled();
  });
});

describe("speak — HTTP 서버 폴백 경로 (tts-venv 없음)", () => {
  beforeEach(() => {
    vi.mocked(fs.existsSync).mockReturnValue(false); // EdgeTTS·MLX 건너뜀
  });

  it("서버 응답 200 → fetch만 호출, spawn 없음", async () => {
    mockFetchOk();
    await speak("안녕", "Sohee");
    expect(fetch).toHaveBeenCalledTimes(2); // health + speak
    expect(cp.spawn).not.toHaveBeenCalled();
  });

  it("서버 speak 500 응답 → say 폴백", async () => {
    mockFetchHealthOkSpeakFail();
    mockSpawnSequence(0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["-v", "Sohee", "안녕"]);
  });

  it("서버 연결 거부 → say 폴백", async () => {
    mockFetchDead();
    mockSpawnSequence(0);
    await speak("안녕");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });
});

describe("speak — macOS say 폴백 경로 (tts-venv 없음, HTTP 없음)", () => {
  beforeEach(() => {
    vi.mocked(fs.existsSync).mockReturnValue(false); // EdgeTTS·MLX 건너뜀
    mockFetchDead();
  });

  it("기본 목소리(시스템) — -v 없이 say 호출", async () => {
    mockSpawnSequence(0);
    await expect(speak("안녕")).resolves.toBeUndefined();
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });

  it("macOS 목소리 지정 시 -v 옵션 포함", async () => {
    mockSpawnSequence(0);
    await speak("안녕", "Yuna");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["-v", "Yuna", "안녕"]);
  });

  it("say 실패 시 reject", async () => {
    mockSpawnSequence(1);
    await expect(speak("안녕")).rejects.toThrow("say 명령 실패");
  });

  it("spawn 오류 시 reject", async () => {
    const proc = new EventEmitter() as any;
    proc.stderr = new EventEmitter();
    vi.mocked(cp.spawn).mockReturnValueOnce(proc as any);
    setImmediate(() => proc.emit("error", new Error("ENOENT")));
    await expect(speak("안녕")).rejects.toThrow("ENOENT");
  });
});

describe("speak — MLX TTS 폴백 경로 (EdgeTTS 실패, HTTP 없음)", () => {
  beforeEach(() => {
    vi.mocked(fs.existsSync).mockReturnValue(true); // tts-venv 존재 (MLX 활성)
    mockFetchDead();
  });

  it("Sohee — EdgeTTS 실패 후 mlx_audio.tts.generate 호출", async () => {
    mockSpawnSequence(1, 0); // EdgeTTS python3 fail, MLX success
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining("python3"),
      expect.arrayContaining(["-m", "mlx_audio.tts.generate", "--voice", "Sohee"]),
      expect.any(Object),
    );
  });

  it("MLX TTS 실패 시 reject", async () => {
    mockSpawnSequence(1, 1); // EdgeTTS fail, MLX fail
    await expect(speak("안녕", "Sohee")).rejects.toThrow("MLX TTS 실패");
  });

  it("tts-venv 없으면 MLX 건너뜀 → say 폴백", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(false);
    mockSpawnSequence(0);
    await speak("안녕", "Sohee");
    expect(cp.spawn).toHaveBeenCalledWith("say", ["-v", "Sohee", "안녕"]);
  });

  it("speak 성공 시 saveLastMessage 호출", async () => {
    const proc = makeOnceProc(0);
    vi.mocked(cp.spawn).mockReturnValue(proc);
    await speak("테스트", "Sohee", 1.0, "");
    expect(vi.mocked(store.saveLastMessage)).toHaveBeenCalledWith("테스트");
  });
});

describe("speakAgent", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    (existsSync as ReturnType<typeof vi.fn>).mockReturnValue(true);
  });

  it("Supertonic 서버가 응답하면 WAV를 재생하고 임시 파일을 삭제한다", async () => {
    const fakeWav = Buffer.from("RIFF");
    global.fetch = vi.fn()
      .mockResolvedValueOnce({ ok: true } as Response)
      .mockResolvedValueOnce({
        ok: true,
        arrayBuffer: async () => fakeWav.buffer,
      } as unknown as Response);

    const spawnMock = vi.fn().mockImplementation((_cmd: string, _args: string[]) => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(cp.spawn).mockImplementation(spawnMock);

    await speakAgent("안녕하세요", "M2", 7788, 1.2);

    expect(writeFileSync).toHaveBeenCalled();
    expect(unlinkSync).toHaveBeenCalled();
  });

  it("Supertonic 서버가 없으면(ECONNREFUSED) 기존 speak()로 폴백한다", async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error("ECONNREFUSED"));

    const spawnMock = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(cp.spawn).mockImplementation(spawnMock);

    await speakAgent("테스트", "M2", 7788, 1.2);
    expect(spawnMock).toHaveBeenCalled();
  });

  it("Supertonic 서버 응답 없음(500ms 타임아웃) → speak()로 폴백한다", async () => {
    vi.useFakeTimers();
    // EdgeTTS·MLX 건너뜀 → say 폴백까지 즉시 진행
    (existsSync as ReturnType<typeof vi.fn>).mockReturnValue(false);

    // Supertonic health(7788): AbortSignal을 존중하는 hanging fetch
    // 그 외 fetch(HTTP TTS 서버 7777 등): 즉시 거부
    global.fetch = vi.fn().mockImplementation((url: string, opts?: RequestInit) => {
      if ((url as string).includes("7788")) {
        return new Promise<Response>((_, reject) => {
          opts?.signal?.addEventListener("abort", () =>
            reject(new DOMException("The operation was aborted", "AbortError")),
          );
        });
      }
      return Promise.reject(new Error("ECONNREFUSED"));
    });

    const spawnMock = vi.fn().mockImplementation(() => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(cp.spawn).mockImplementation(spawnMock);

    const promise = speakAgent("타임아웃 테스트", "M2", 7788, 1.2);
    // 500ms 타임아웃 + 여유 100ms 전진 → AbortController 발동
    await vi.advanceTimersByTimeAsync(600);
    await promise;

    vi.useRealTimers();
    // say 폴백이 실제로 호출됐는지 검증
    expect(spawnMock).toHaveBeenCalledWith("say", ["타임아웃 테스트"]);
  });
});
