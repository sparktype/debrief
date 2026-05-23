// macOS say 명령으로 텍스트를 음성 재생
import { spawn } from "child_process";

export function speak(text: string, voice = "Yuna"): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("say", ["-v", voice, text]);
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`say 명령 실패: exit ${code}`));
    });
    proc.on("error", reject);
  });
}
