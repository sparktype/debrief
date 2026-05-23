// EdgeTTS(온라인 우선) → HTTP TTS 서버 → MLX subprocess → macOS say 순서로 음성 재생
import { spawn } from "child_process";
import { existsSync, unlinkSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
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
// MLX 스피커 이름 → EdgeTTS 한국어 Neural 음성 매핑
const EDGE_VOICE_MAP = {
    Sohee: "ko-KR-SunHiNeural",
    Vivian: "ko-KR-SunHiNeural",
    Serena: "ko-KR-SunHiNeural",
    Uncle_Fu: "ko-KR-SunHiNeural",
    Ono_Anna: "ko-KR-SunHiNeural",
    Ryan: "ko-KR-InJoonNeural",
    Eric: "ko-KR-InJoonNeural",
    Dylan: "ko-KR-InJoonNeural",
    Aiden: "ko-KR-HyunsuMultilingualNeural",
};
// edge-tts Python API를 argv로 호출 — 쉘 이스케이프 없이 텍스트 전달
const EDGE_SCRIPT = "import asyncio, edge_tts, sys; " +
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
        const proc = opts ? spawn(cmd, args, opts) : spawn(cmd, args);
        proc.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`${cmd} 실패: exit ${code}`));
        });
        proc.on("error", reject);
    });
}
async function speakEdge(text, voice, speed) {
    const edgeVoice = EDGE_VOICE_MAP[voice] ?? "ko-KR-SunHiNeural";
    const outFile = `/tmp/siren_edge_${Date.now()}.mp3`;
    const edgePromise = (async () => {
        await spawnPromise(MLX_PYTHON, ["-c", EDGE_SCRIPT, text, edgeVoice, outFile]);
        await spawnPromise("afplay", ["-r", String(speed), outFile]);
        try {
            unlinkSync(outFile);
        }
        catch { /* 임시 파일 정리 실패 무시 */ }
    })();
    await Promise.race([
        edgePromise,
        new Promise((_, reject) => setTimeout(() => reject(new Error("EdgeTTS 타임아웃")), EDGE_TIMEOUT_MS)),
    ]);
}
function speakSubprocess(text, voice, speed, instruct) {
    if (MLX_SPEAKERS.has(voice) && existsSync(MLX_PYTHON)) {
        return speakMLX(text, voice, speed, instruct);
    }
    return speakSay(text, voice);
}
export async function speak(text, voice = "", speed = 1.2, instruct = "") {
    // 1. EdgeTTS (온라인 우선, tts-venv에 edge-tts 설치 필요)
    if (existsSync(MLX_PYTHON)) {
        try {
            await speakEdge(text, voice, speed);
            return;
        }
        catch {
            // 네트워크 오류 또는 타임아웃 시 폴백
        }
    }
    // 2. HTTP TTS 서버 (MLX 상주 서버가 기동 중인 경우)
    if (await isTTSServerAlive()) {
        try {
            await speakHTTP(text, voice, speed, instruct);
            return;
        }
        catch {
            // 서버 응답 실패 시 폴백
        }
    }
    // 3. MLX subprocess → 4. macOS say
    return speakSubprocess(text, voice, speed, instruct);
}
