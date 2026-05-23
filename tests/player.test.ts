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
  return {
    ...orig,
    existsSync: vi.fn(() => true),
    unlinkSync: vi.fn(),
    writeFileSync: vi.fn(),
    // withTTSLock 잠금 관련 — 항상 즉시 취득 성공으로 처리
    openSync: vi.fn(() => 3),
    writeSync: vi.fn(),
    closeSync: vi.fn(),
    readFileSync: vi.fn(() => "0"),
  };
});

vi.mock("../src/last-message-store.js", () => ({
  saveLastMessage: vi.fn(),
}));
import * as store from "../src/last-message-store.js";

import { speak, speakAgent, splitByLanguage, mergeWavBuffers } from "../src/player.js";
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

  it("한영 혼합 텍스트 → batch 경로 (/v1/tts/batch 호출)", async () => {
    // 최소 유효 WAV: RIFF + fmt + data 청크
    function makeWav(pcm: Buffer): Buffer {
      const fmtChunk = Buffer.alloc(24);
      fmtChunk.write("fmt ", 0);
      fmtChunk.writeUInt32LE(16, 4);
      fmtChunk.writeUInt16LE(1, 8);   // PCM
      fmtChunk.writeUInt16LE(1, 10);  // 모노
      fmtChunk.writeUInt32LE(44100, 12);
      fmtChunk.writeUInt32LE(88200, 16);
      fmtChunk.writeUInt16LE(2, 20);
      fmtChunk.writeUInt16LE(16, 22);
      const dataHeader = Buffer.alloc(8);
      dataHeader.write("data", 0);
      dataHeader.writeUInt32LE(pcm.length, 4);
      const riffBody = Buffer.concat([Buffer.from("WAVE"), fmtChunk, dataHeader, pcm]);
      const riff = Buffer.alloc(8);
      riff.write("RIFF", 0);
      riff.writeUInt32LE(riffBody.length, 4);
      return Buffer.concat([riff, riffBody]);
    }

    const wav1 = makeWav(Buffer.from([0x01, 0x02]));
    const wav2 = makeWav(Buffer.from([0x03, 0x04]));

    global.fetch = vi.fn()
      .mockResolvedValueOnce({ ok: true } as Response)  // health
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          items: [
            { audio_base64: wav1.toString("base64") },
            { audio_base64: wav2.toString("base64") },
          ],
        }),
      } as unknown as Response);  // /v1/tts/batch

    const spawnMock = vi.fn().mockImplementation(() => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(cp.spawn).mockImplementation(spawnMock);

    await speakAgent("리뷰어입니다. TypeScript 수정 완료", "M2", 7788, 1.2);

    const batchCall = vi.mocked(global.fetch).mock.calls.find(
      ([url]) => (url as string).includes("tts/batch")
    );
    expect(batchCall).toBeDefined();
    const body = JSON.parse(batchCall![1]!.body as string);
    expect(body.items.length).toBeGreaterThan(1);
    // 영문 구간은 "en", 한글 구간은 "ko" 확인
    const langs = body.items.map((it: any) => it.lang);
    expect(langs).toContain("en");
    expect(langs).toContain("ko");
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

describe("splitByLanguage", () => {
  it("순수 한국어 → 구간 1개 (ko)", () => {
    const segs = splitByLanguage("리뷰어입니다.");
    expect(segs).toHaveLength(1);
    expect(segs[0]).toEqual({ text: "리뷰어입니다.", lang: "ko" });
  });

  it("순수 영어 → 구간 1개 (en)", () => {
    const segs = splitByLanguage("TypeScript");
    expect(segs).toHaveLength(1);
    expect(segs[0]).toEqual({ text: "TypeScript", lang: "en" });
  });

  it("혼합 문장 → ko/en/ko 구간 분리", () => {
    const segs = splitByLanguage("리뷰어입니다. TypeScript 수정 완료");
    const langs = segs.map(s => s.lang);
    expect(langs).toContain("ko");
    expect(langs).toContain("en");
    const enSeg = segs.find(s => s.lang === "en")!;
    expect(enSeg.text.trim()).toBe("TypeScript");
  });

  it("하이픈 포함 영어 단어는 하나의 en 구간으로 묶임", () => {
    const segs = splitByLanguage("gpt-5.4 모델");
    const enSeg = segs.find(s => s.lang === "en")!;
    expect(enSeg.text.trim()).toBe("gpt-5.4");
  });

  it("빈 문자열 → 빈 배열", () => {
    expect(splitByLanguage("")).toHaveLength(0);
    expect(splitByLanguage("   ")).toHaveLength(0);
  });
});

describe("mergeWavBuffers", () => {
  function makeWav(pcmBytes: number[]): Buffer {
    const pcm = Buffer.from(pcmBytes);
    const fmtChunk = Buffer.alloc(24);
    fmtChunk.write("fmt ", 0);
    fmtChunk.writeUInt32LE(16, 4);
    fmtChunk.writeUInt16LE(1, 8);
    fmtChunk.writeUInt16LE(1, 10);
    fmtChunk.writeUInt32LE(44100, 12);
    fmtChunk.writeUInt32LE(88200, 16);
    fmtChunk.writeUInt16LE(2, 20);
    fmtChunk.writeUInt16LE(16, 22);
    const dataHeader = Buffer.alloc(8);
    dataHeader.write("data", 0);
    dataHeader.writeUInt32LE(pcm.length, 4);
    const body = Buffer.concat([Buffer.from("WAVE"), fmtChunk, dataHeader, pcm]);
    const riff = Buffer.alloc(8);
    riff.write("RIFF", 0);
    riff.writeUInt32LE(body.length, 4);
    return Buffer.concat([riff, body]);
  }

  it("버퍼 1개 → 그대로 반환", () => {
    const wav = makeWav([1, 2, 3, 4]);
    expect(mergeWavBuffers([wav])).toBe(wav);
  });

  it("버퍼 2개 → PCM 이어붙임, 'RIFF' 헤더 유지", () => {
    const wav1 = makeWav([0x01, 0x02]);
    const wav2 = makeWav([0x03, 0x04]);
    const merged = mergeWavBuffers([wav1, wav2]);
    expect(merged.slice(0, 4).toString()).toBe("RIFF");
    // 병합된 PCM에 두 버퍼의 데이터가 모두 포함됨
    const dataOffset = merged.indexOf(Buffer.from("data")) + 8;
    const pcm = merged.slice(dataOffset);
    expect(pcm.includes(Buffer.from([0x01, 0x02]))).toBe(true);
    expect(pcm.includes(Buffer.from([0x03, 0x04]))).toBe(true);
  });

  it("병합 후 data 청크 크기가 정확히 갱신됨", () => {
    const wav1 = makeWav([0x01, 0x02]);
    const wav2 = makeWav([0x03, 0x04]);
    const merged = mergeWavBuffers([wav1, wav2]);
    const dataIdx = merged.indexOf(Buffer.from("data"));
    const dataSize = merged.readUInt32LE(dataIdx + 4);
    expect(dataSize).toBe(4); // 2 + 2 바이트
  });
});
