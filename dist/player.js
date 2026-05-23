// macOS say 명령으로 텍스트를 음성 재생
import { spawn } from "child_process";
export function speak(text) {
    return new Promise((resolve, reject) => {
        const proc = spawn("say", [text]);
        proc.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`say 명령 실패: exit ${code}`));
        });
        proc.on("error", reject);
    });
}
