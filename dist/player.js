// macOS say, MLX TTS(Sohee 등), 또는 HTTP TTS 서버로 텍스트를 음성 재생
import { spawn } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
const __dirname = dirname(fileURLToPath(import.meta.url));
const MLX_PYTHON = join(__dirname, "..", "tts-venv", "bin", "python3");
const MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit";
const TTS_SERVER_BASE = "http://localhost:7777";
const HEALTH_TIMEOUT_MS = 500;
const SPEAK_TIMEOUT_MS = 10000;
// CustomVoice 모델에 내장된 스피커 목록
const MLX_SPEAKERS = new Set([
    "Sohee", "Vivian", "Serena", "Uncle_Fu",
    "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna",
]);
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
function speakSubprocess(text, voice, speed, instruct) {
    if (MLX_SPEAKERS.has(voice) && existsSync(MLX_PYTHON)) {
        return speakMLX(text, voice, speed, instruct);
    }
    return speakSay(text, voice);
}
export async function speak(text, voice = "", speed = 1.2, instruct = "") {
    if (await isTTSServerAlive()) {
        try {
            await speakHTTP(text, voice, speed, instruct);
            return;
        }
        catch {
            // 서버 응답 실패 시 subprocess 폴백
        }
    }
    return speakSubprocess(text, voice, speed, instruct);
}
