// EdgeTTS(온라인 우선) → HTTP TTS 서버 → MLX subprocess → macOS say 순서로 음성 재생
import { spawn, SpawnOptions } from "child_process";
import { existsSync, unlinkSync, writeFileSync, openSync, writeSync, closeSync, readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { saveLastMessage } from "./last-message-store.js";

// 동시 발화 방지 — 프로세스 간 파일 기반 배타 잠금
const TTS_LOCK_FILE = "/tmp/siren-tts.lock";
const LOCK_STALE_MS = 30_000;
const LOCK_WAIT_MS  = 25_000;

async function withTTSLock<T>(fn: () => Promise<T>): Promise<T> {
  const deadline = Date.now() + LOCK_WAIT_MS;
  let acquired = false;
  while (!acquired) {
    try {
      // O_CREAT|O_EXCL — 원자적 배타 생성
      const fd = openSync(TTS_LOCK_FILE, "wx");
      writeSync(fd, String(Date.now()));
      closeSync(fd);
      acquired = true;
    } catch {
      try {
        const t = parseInt(readFileSync(TTS_LOCK_FILE, "utf-8"), 10);
        if (isNaN(t) || Date.now() - t > LOCK_STALE_MS) {
          unlinkSync(TTS_LOCK_FILE);
          continue;
        }
      } catch { break; }
      if (Date.now() > deadline) break;
      await new Promise(r => setTimeout(r, 300));
    }
  }
  try {
    return await fn();
  } finally {
    if (acquired) try { unlinkSync(TTS_LOCK_FILE); } catch { /* 무시 */ }
  }
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const MLX_PYTHON = join(__dirname, "..", "tts-venv", "bin", "python3");
const MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit";

const TTS_SERVER_BASE = "http://localhost:7777";
const HEALTH_TIMEOUT_MS = 500;
const SPEAK_TIMEOUT_MS = 10000;
const EDGE_TIMEOUT_MS = 10000;

// CustomVoice 모델에 내장된 스피커 목록
const MLX_SPEAKERS = new Set([
  "Sohee", "Vivian", "Serena", "Uncle_Fu",
  "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna",
]);

// 한영 혼합 발음을 위해 전체 HyunsuMultilingualNeural 통일
// <lang xml:lang="en-US"> 태그는 Multilingual 음성에서만 동작
const EDGE_VOICE_MAP: Record<string, string> = {
  Sohee:    "ko-KR-HyunsuMultilingualNeural",
  Vivian:   "ko-KR-HyunsuMultilingualNeural",
  Serena:   "ko-KR-HyunsuMultilingualNeural",
  Uncle_Fu: "ko-KR-HyunsuMultilingualNeural",
  Ono_Anna: "ko-KR-HyunsuMultilingualNeural",
  Ryan:     "ko-KR-HyunsuMultilingualNeural",
  Eric:     "ko-KR-HyunsuMultilingualNeural",
  Dylan:    "ko-KR-HyunsuMultilingualNeural",
  Aiden:    "ko-KR-HyunsuMultilingualNeural",
};

// edge-tts Python API를 argv로 호출 — 쉘 이스케이프 없이 텍스트 전달
// SSL 검증 비활성화: HMG 사내 프록시가 자체 CA로 TLS를 인터셉트하기 때문에 certifi 번들 검증 실패
// 한영 혼합 발음: Microsoft 무료 TTS 엔드포인트는 prosody body 내 SSML 태그를 지원하지 않으므로
// HyunsuMultilingualNeural 음성의 자동 언어 감지 기능에 의존
const EDGE_SCRIPT =
  "import asyncio, edge_tts, edge_tts.communicate as ec, ssl, sys; " +
  "ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE; ec._SSL_CTX=ctx; " +
  "asyncio.run(edge_tts.Communicate(sys.argv[1], sys.argv[2]).save(sys.argv[3]))";

async function isTTSServerAlive(): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), HEALTH_TIMEOUT_MS);
    const res = await fetch(`${TTS_SERVER_BASE}/health`, { signal: ctrl.signal });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

async function speakHTTP(text: string, voice: string, speed: number, instruct: string): Promise<void> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), SPEAK_TIMEOUT_MS);
  try {
    const res = await fetch(`${TTS_SERVER_BASE}/speak`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, voice, lang_code: "korean", speed, instruct }),
      signal: ctrl.signal,
    });
    if (res.status === 429) {
      return; // 이미 재생 중 — 스킵
    }
    if (!res.ok) throw new Error(`TTS 서버 응답 오류: ${res.status}`);
  } finally {
    clearTimeout(timer);
  }
}

function speakMLX(text: string, voice: string, speed: number, instruct: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const args = [
      "-m", "mlx_audio.tts.generate",
      "--model", MLX_MODEL,
      "--text", text,
      "--voice", voice,
      "--lang_code", "korean",
      "--speed", String(speed),
      "--output_path", "/tmp",
      "--play",
    ];
    if (instruct) args.push("--instruct", instruct);
    const proc = spawn(MLX_PYTHON, args, { env: { ...process.env, HF_HUB_OFFLINE: "1" } });
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`MLX TTS 실패: exit ${code}`));
    });
    proc.on("error", reject);
  });
}

function speakSay(text: string, voice: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const args = voice ? ["-v", voice, text] : [text];
    const proc = spawn("say", args);
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`say 명령 실패: exit ${code}`));
    });
    proc.on("error", reject);
  });
}

function spawnPromise(cmd: string, args: string[], opts?: SpawnOptions): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, opts ?? {});
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} 실패: exit ${code}`));
    });
    proc.on("error", reject);
  });
}

async function speakEdge(text: string, voice: string, speed: number): Promise<void> {
  const edgeVoice = EDGE_VOICE_MAP[voice] ?? "ko-KR-HyunsuMultilingualNeural";
  const outFile = `/tmp/siren_edge_${Date.now()}.mp3`;
  // proc을 outer scope에 선언해 타임아웃 시 kill 가능하도록
  let proc: ReturnType<typeof spawn> | undefined;
  const edgePromise = new Promise<void>((resolve, reject) => {
    proc = spawn(MLX_PYTHON, ["-c", EDGE_SCRIPT, text, edgeVoice, outFile]);
    proc.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
    proc.on("error", reject);
  });
  try {
    await Promise.race([
      edgePromise,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("EdgeTTS 타임아웃")), EDGE_TIMEOUT_MS)
      ),
    ]);
  } catch (e) {
    // 타임아웃 또는 오류 시 orphan 프로세스 종료 + 임시 파일 삭제
    proc?.kill();
    try { unlinkSync(outFile); } catch { /* 무시 */ }
    throw e;
  }
  // 재생은 완료까지 기다림
  try {
    await spawnPromise("afplay", ["-r", String(speed), outFile]);
  } finally {
    try { unlinkSync(outFile); } catch { /* 임시 파일 정리 실패 무시 */ }
  }
}

function speakSubprocess(text: string, voice: string, speed: number, instruct: string): Promise<void> {
  if (MLX_SPEAKERS.has(voice) && existsSync(MLX_PYTHON)) {
    return speakMLX(text, voice, speed, instruct);
  }
  return speakSay(text, voice);
}

async function isSupertonicAlive(port: number): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 500);
    const res = await fetch(`http://localhost:${port}/v1/health`, { signal: ctrl.signal });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

// 한영 혼합 처리를 위한 언어 구간 타입
type LangSegment = { text: string; lang: "ko" | "en" };

// 영문자 연속 구간을 "en", 나머지를 "ko"로 분리
// 공백·구두점은 앞 구간에 붙여 구간 경계에서 끊김 방지
export function splitByLanguage(text: string): LangSegment[] {
  // 영문자로 시작하는 단어 기준 분리 (하이픈·언더스코어·점 포함: gpt-5.4, my_func)
  const parts = text.split(/([A-Za-z][A-Za-z0-9\-_.]*)/);
  const segs: LangSegment[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!parts[i]) continue;
    const lang: "ko" | "en" = i % 2 === 1 ? "en" : "ko";
    if (!parts[i].trim()) {
      // 공백만 있는 구간 — 이전 구간에 붙임 (자연스러운 경계 유지)
      if (segs.length > 0) segs[segs.length - 1].text += parts[i];
    } else if (segs.length > 0 && segs[segs.length - 1].lang === lang) {
      segs[segs.length - 1].text += parts[i];
    } else {
      segs.push({ text: parts[i], lang });
    }
  }
  return segs.filter(s => s.text.trim());
}

// WAV 버퍼에서 "data" 청크 시작 오프셋 반환
function findDataOffset(buf: Buffer): number {
  for (let i = 12; i < buf.length - 8; i++) {
    if (buf[i] === 0x64 && buf[i + 1] === 0x61 && buf[i + 2] === 0x74 && buf[i + 3] === 0x61) {
      return i;
    }
  }
  throw new Error("WAV 'data' 청크 없음");
}

// 여러 WAV 버퍼를 하나로 병합 — PCM 데이터를 이어붙이고 헤더 크기 필드 갱신
export function mergeWavBuffers(buffers: Buffer[]): Buffer {
  if (buffers.length === 1) return buffers[0];
  const offsets = buffers.map(findDataOffset);
  const pcms = buffers.map((b, i) => b.slice(offsets[i] + 8));
  const pcm = Buffer.concat(pcms);
  const header = Buffer.from(buffers[0].slice(0, offsets[0] + 8));
  header.writeUInt32LE(pcm.length, offsets[0] + 4);         // data 청크 크기 갱신
  header.writeUInt32LE(header.length + pcm.length - 8, 4);  // RIFF 청크 크기 갱신
  return Buffer.concat([header, pcm]);
}

async function speakSupertonic(text: string, voice: string, port: number, speed: number): Promise<void> {
  const segments = splitByLanguage(text);
  const outFile = `/tmp/siren_supertonic_${Date.now()}.wav`;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 20000);
  try {
    let audioBuf: Buffer;
    if (segments.length <= 1) {
      // 단일 언어 — /v1/audio/speech
      const lang = segments[0]?.lang ?? "ko";
      const res = await fetch(`http://localhost:${port}/v1/audio/speech`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: "supertonic-3", input: text, voice, response_format: "wav", lang }),
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`Supertonic 응답 오류: ${res.status}`);
      audioBuf = Buffer.from(await res.arrayBuffer());
    } else {
      // 혼합 언어 — /v1/tts/batch (구간별 lang 지정)
      const res = await fetch(`http://localhost:${port}/v1/tts/batch`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          items: segments.map(s => ({ text: s.text, voice, lang: s.lang })),
          response_format: "wav",
        }),
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`Supertonic batch 오류: ${res.status}`);
      const { items } = await res.json() as { items: { audio_base64: string }[] };
      audioBuf = mergeWavBuffers(items.map(it => Buffer.from(it.audio_base64, "base64")));
    }
    writeFileSync(outFile, audioBuf);
    await spawnPromise("afplay", ["-r", String(speed), outFile]);
  } finally {
    clearTimeout(timer);
    try { unlinkSync(outFile); } catch { /* 임시 파일 정리 실패 무시 */ }
  }
}

export async function speakAgent(
  text: string,
  supertonicVoice: string,
  port: number,
  speed: number,
): Promise<void> {
  return withTTSLock(async () => {
    if (await isSupertonicAlive(port)) {
      try {
        await speakSupertonic(text, supertonicVoice, port, speed);
        saveLastMessage(text);
        return;
      } catch {
        // Supertonic 실패 시 기존 체인으로 폴백
      }
    }
    await speakInner(text, "", speed, "");
  });
}

export async function speak(text: string, voice = "", speed = 1.2, instruct = ""): Promise<void> {
  return withTTSLock(() => speakInner(text, voice, speed, instruct));
}

async function speakInner(text: string, voice = "", speed = 1.2, instruct = ""): Promise<void> {
  // 1. EdgeTTS (온라인 우선, tts-venv에 edge-tts 설치 필요, SIREN_OFFLINE=1이면 건너뜀)
  const skipEdge = process.env.SIREN_OFFLINE === "1";
  if (!skipEdge && existsSync(MLX_PYTHON)) {
    try {
      await speakEdge(text, voice, speed);
      saveLastMessage(text);
      return;
    } catch {
      // 네트워크 오류 또는 타임아웃 시 폴백
    }
  }
  // 2. HTTP TTS 서버 (MLX 상주 서버가 기동 중인 경우)
  if (await isTTSServerAlive()) {
    try {
      await speakHTTP(text, voice, speed, instruct);
      saveLastMessage(text);
      return;
    } catch {
      // 서버 응답 실패 시 폴백
    }
  }
  // 3. MLX subprocess → 4. macOS say
  await speakSubprocess(text, voice, speed, instruct);
  saveLastMessage(text);
}
