// EdgeTTS(온라인 우선) → HTTP TTS 서버 → MLX subprocess → macOS say 순서로 음성 재생
import { spawn } from "child_process";
import { existsSync, unlinkSync, writeFileSync, openSync, writeSync, closeSync, readFileSync, mkdirSync, renameSync, } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { saveLastMessage } from "./last-message-store.js";
// ── 파일 스풀 ────────────────────────────────────────────────
// 생성된 오디오 파일을 스풀에 이동 — 데몬이 epoch_ms 순서대로 재생
const SPOOL_DIR = "/tmp/tts-spool";
function ensureSpoolDir() {
    mkdirSync(SPOOL_DIR, { recursive: true });
}
function enqueueSpool(tmpFile, speed) {
    const ts = Date.now();
    const ext = tmpFile.split(".").pop() ?? "wav";
    ensureSpoolDir();
    renameSync(tmpFile, `${SPOOL_DIR}/${ts}.${ext}`);
    writeFileSync(`${SPOOL_DIR}/${ts}.meta`, String(speed));
}
// ── 동시 발화 방지 (speak() 직접 재생 경로 전용) ────────────
const TTS_LOCK_FILE = "/tmp/siren-tts.lock";
const LOCK_STALE_MS = 30_000;
const LOCK_WAIT_MS = 25_000;
async function withTTSLock(fn) {
    const deadline = Date.now() + LOCK_WAIT_MS;
    let acquired = false;
    while (!acquired) {
        try {
            const fd = openSync(TTS_LOCK_FILE, "wx");
            writeSync(fd, String(Date.now()));
            closeSync(fd);
            acquired = true;
        }
        catch {
            try {
                const t = parseInt(readFileSync(TTS_LOCK_FILE, "utf-8"), 10);
                if (isNaN(t) || Date.now() - t > LOCK_STALE_MS) {
                    unlinkSync(TTS_LOCK_FILE);
                }
            }
            catch { /* ENOENT: 다음 루프에서 openSync 재시도 */ }
            if (Date.now() > deadline)
                return undefined; // 타임아웃 — 스킵
            await new Promise(r => setTimeout(r, 300));
        }
    }
    try {
        return await fn();
    }
    finally {
        try {
            unlinkSync(TTS_LOCK_FILE);
        }
        catch { /* 무시 */ }
    }
}
const __dirname = dirname(fileURLToPath(import.meta.url));
const MLX_PYTHON = join(__dirname, "..", "tts-venv", "bin", "python3");
const MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit";
const TTS_SERVER_BASE = "http://localhost:7777";
const HEALTH_TIMEOUT_MS = 500;
const SPEAK_TIMEOUT_MS = 10000;
const EDGE_TIMEOUT_MS = 10000;
const MLX_SPEAKERS = new Set([
    "Sohee", "Vivian", "Serena", "Uncle_Fu",
    "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna",
]);
// 한영 혼합 발음을 위해 전체 HyunsuMultilingualNeural 통일
// SSL 검증 비활성화: HMG 사내 프록시가 자체 CA로 TLS를 인터셉트하기 때문에 certifi 번들 검증 실패
const EDGE_VOICE_MAP = {
    Sohee: "ko-KR-HyunsuMultilingualNeural",
    Vivian: "ko-KR-HyunsuMultilingualNeural",
    Serena: "ko-KR-HyunsuMultilingualNeural",
    Uncle_Fu: "ko-KR-HyunsuMultilingualNeural",
    Ono_Anna: "ko-KR-HyunsuMultilingualNeural",
    Ryan: "ko-KR-HyunsuMultilingualNeural",
    Eric: "ko-KR-HyunsuMultilingualNeural",
    Dylan: "ko-KR-HyunsuMultilingualNeural",
    Aiden: "ko-KR-HyunsuMultilingualNeural",
};
const EDGE_SCRIPT = "import asyncio, edge_tts, edge_tts.communicate as ec, ssl, sys; " +
    "ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE; ec._SSL_CTX=ctx; " +
    "asyncio.run(edge_tts.Communicate(sys.argv[1], sys.argv[2]).save(sys.argv[3]))";
async function isTTSServerAlive() {
    try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), HEALTH_TIMEOUT_MS);
        const res = await fetch(`${TTS_SERVER_BASE}/health`, { signal: ctrl.signal });
        clearTimeout(timer);
        return res.ok;
    }
    catch {
        return false;
    }
}
async function speakHTTP(text, voice, speed, instruct) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), SPEAK_TIMEOUT_MS);
    try {
        const res = await fetch(`${TTS_SERVER_BASE}/speak`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ text, voice, lang_code: "korean", speed, instruct }),
            signal: ctrl.signal,
        });
        if (res.status === 429)
            return;
        if (!res.ok)
            throw new Error(`TTS 서버 응답 오류: ${res.status}`);
    }
    finally {
        clearTimeout(timer);
    }
}
function speakMLX(text, voice, speed, instruct) {
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
        if (instruct)
            args.push("--instruct", instruct);
        const proc = spawn(MLX_PYTHON, args, { env: { ...process.env, HF_HUB_OFFLINE: "1" } });
        proc.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`MLX TTS 실패: exit ${code}`));
        });
        proc.on("error", reject);
    });
}
function speakSay(text, voice) {
    return new Promise((resolve, reject) => {
        const args = voice ? ["-v", voice, text] : [text];
        const proc = spawn("say", args);
        proc.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`say 명령 실패: exit ${code}`));
        });
        proc.on("error", reject);
    });
}
function spawnPromise(cmd, args, opts) {
    return new Promise((resolve, reject) => {
        const proc = spawn(cmd, args, opts ?? {});
        proc.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`${cmd} 실패: exit ${code}`));
        });
        proc.on("error", reject);
    });
}
// EdgeTTS로 MP3 파일 생성 — 재생하지 않고 파일 경로 반환
async function generateEdge(text, voice) {
    const edgeVoice = EDGE_VOICE_MAP[voice] ?? "ko-KR-HyunsuMultilingualNeural";
    const outFile = `/tmp/siren_edge_${Date.now()}.mp3`;
    let proc;
    const edgePromise = new Promise((resolve, reject) => {
        proc = spawn(MLX_PYTHON, ["-c", EDGE_SCRIPT, text, edgeVoice, outFile]);
        proc.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
        proc.on("error", reject);
    });
    try {
        await Promise.race([
            edgePromise,
            new Promise((_, reject) => setTimeout(() => reject(new Error("EdgeTTS 타임아웃")), EDGE_TIMEOUT_MS)),
        ]);
    }
    catch (e) {
        proc?.kill();
        try {
            unlinkSync(outFile);
        }
        catch { /* 무시 */ }
        throw e;
    }
    return outFile;
}
// EdgeTTS 생성 + 즉시 재생 (speak() 직접 재생 경로용)
async function speakEdge(text, voice, speed) {
    const outFile = await generateEdge(text, voice);
    try {
        await spawnPromise("afplay", ["-r", String(speed), outFile]);
    }
    finally {
        try {
            unlinkSync(outFile);
        }
        catch { /* 무시 */ }
    }
}
function speakSubprocess(text, voice, speed, instruct) {
    if (MLX_SPEAKERS.has(voice) && existsSync(MLX_PYTHON)) {
        return speakMLX(text, voice, speed, instruct);
    }
    return speakSay(text, voice);
}
async function isSupertonicAlive(port) {
    try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 500);
        const res = await fetch(`http://localhost:${port}/v1/health`, { signal: ctrl.signal });
        clearTimeout(timer);
        return res.ok;
    }
    catch {
        return false;
    }
}
// 영문자 연속 구간을 "en", 나머지를 "ko"로 분리
export function splitByLanguage(text) {
    const parts = text.split(/([A-Za-z][A-Za-z0-9\-_.]*)/);
    const segs = [];
    for (let i = 0; i < parts.length; i++) {
        if (!parts[i])
            continue;
        const lang = i % 2 === 1 ? "en" : "ko";
        if (!parts[i].trim()) {
            if (segs.length > 0)
                segs[segs.length - 1].text += parts[i];
        }
        else if (segs.length > 0 && segs[segs.length - 1].lang === lang) {
            segs[segs.length - 1].text += parts[i];
        }
        else {
            segs.push({ text: parts[i], lang });
        }
    }
    return segs.filter(s => s.text.trim());
}
// WAV 버퍼에서 "data" 청크 시작 오프셋 반환
function findDataOffset(buf) {
    for (let i = 12; i < buf.length - 8; i++) {
        if (buf[i] === 0x64 && buf[i + 1] === 0x61 && buf[i + 2] === 0x74 && buf[i + 3] === 0x61) {
            return i;
        }
    }
    throw new Error("WAV 'data' 청크 없음");
}
// 여러 WAV 버퍼를 하나로 병합 — PCM 데이터를 이어붙이고 헤더 크기 필드 갱신
export function mergeWavBuffers(buffers) {
    if (buffers.length === 1)
        return buffers[0];
    const offsets = buffers.map(findDataOffset);
    const pcms = buffers.map((b, i) => b.slice(offsets[i] + 8));
    const pcm = Buffer.concat(pcms);
    const header = Buffer.from(buffers[0].slice(0, offsets[0] + 8));
    header.writeUInt32LE(pcm.length, offsets[0] + 4);
    header.writeUInt32LE(header.length + pcm.length - 8, 4);
    return Buffer.concat([header, pcm]);
}
// Supertonic WAV 생성 (재생 없음) — 에이전트 스풀 경로용
async function generateSupertonic(text, voice, port) {
    const segments = splitByLanguage(text);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 20000);
    try {
        if (segments.length <= 1) {
            const lang = segments[0]?.lang ?? "ko";
            const res = await fetch(`http://localhost:${port}/v1/audio/speech`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ model: "supertonic-3", input: text, voice, response_format: "wav", lang }),
                signal: ctrl.signal,
            });
            if (!res.ok)
                throw new Error(`Supertonic 응답 오류: ${res.status}`);
            return Buffer.from(await res.arrayBuffer());
        }
        else {
            const res = await fetch(`http://localhost:${port}/v1/tts/batch`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    items: segments.map(s => ({ text: s.text, voice, lang: s.lang })),
                    response_format: "wav",
                }),
                signal: ctrl.signal,
            });
            if (!res.ok)
                throw new Error(`Supertonic batch 오류: ${res.status}`);
            const { items } = await res.json();
            return mergeWavBuffers(items.map(it => Buffer.from(it.audio_base64, "base64")));
        }
    }
    finally {
        clearTimeout(timer);
    }
}
// ── 리더(hook) 발화: EdgeTTS MP3 생성 → 스풀 → 즉시 반환 ──
// voice: config.voice (예: "Sohee") → EDGE_VOICE_MAP → HyunsuMultilingualNeural
export async function speakHook(text, voice = "Sohee", speed = 1.2) {
    const skipEdge = process.env.SIREN_OFFLINE === "1";
    if (!skipEdge && existsSync(MLX_PYTHON)) {
        try {
            const mp3 = await generateEdge(text, voice);
            enqueueSpool(mp3, speed);
            saveLastMessage(text);
            return;
        }
        catch {
            // EdgeTTS 실패 시 직접 재생 폴백
        }
    }
    await speakInner(text, voice, speed, "");
}
// ── 에이전트(subagent-stop) 발화: Supertonic WAV → 스풀 → 즉시 반환 ──
// withTTSLock 불필요 — 데몬 단일 소비자가 직렬화
export async function speakAgent(text, supertonicVoice, port, speed) {
    if (await isSupertonicAlive(port)) {
        try {
            const wav = await generateSupertonic(text, supertonicVoice, port);
            const tmp = `/tmp/siren_st_${Date.now()}.wav`;
            writeFileSync(tmp, wav);
            enqueueSpool(tmp, speed);
            saveLastMessage(text);
            return;
        }
        catch {
            // Supertonic 실패 시 직접 재생 폴백
        }
    }
    await speakInner(text, "", speed, "");
}
// ── MCP 도구·hook-suggest 전용 직접 재생 경로 ──
export async function speak(text, voice = "", speed = 1.2, instruct = "") {
    await withTTSLock(() => speakInner(text, voice, speed, instruct));
}
async function speakInner(text, voice = "", speed = 1.2, instruct = "") {
    const skipEdge = process.env.SIREN_OFFLINE === "1";
    if (!skipEdge && existsSync(MLX_PYTHON)) {
        try {
            await speakEdge(text, voice, speed);
            saveLastMessage(text);
            return;
        }
        catch { /* 폴백 */ }
    }
    if (await isTTSServerAlive()) {
        try {
            await speakHTTP(text, voice, speed, instruct);
            saveLastMessage(text);
            return;
        }
        catch { /* 폴백 */ }
    }
    await speakSubprocess(text, voice, speed, instruct);
    saveLastMessage(text);
}
