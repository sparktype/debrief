// macOS say 및 MLX TTS(Sohee 등)로 텍스트를 음성 재생
import { spawn } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MLX_PYTHON = join(__dirname, "..", "tts-venv", "bin", "python3");
const MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit";

// CustomVoice 모델에 내장된 스피커 목록
const MLX_SPEAKERS = new Set([
  "Sohee", "Vivian", "Serena", "Uncle_Fu",
  "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna",
]);

function speakMLX(text: string, voice: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(MLX_PYTHON, [
      "-m", "mlx_audio.tts.generate",
      "--model", MLX_MODEL,
      "--text", text,
      "--voice", voice,
      "--lang_code", "Auto",
      "--output_path", "/tmp",
      "--play",
    ], { env: { ...process.env, HF_HUB_OFFLINE: "1" } });
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

export function speak(text: string, voice = ""): Promise<void> {
  if (MLX_SPEAKERS.has(voice) && existsSync(MLX_PYTHON)) {
    return speakMLX(text, voice);
  }
  return speakSay(text, voice);
}
