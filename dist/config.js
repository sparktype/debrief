// 사용자 설정 파일 로더 및 기본값 관리
import { readFileSync, existsSync } from "fs";
const DEFAULTS = {
    autoSpeak: true,
    minChars: 500,
    voice: "Yuna",
    summaryModel: "gpt-4o-mini",
    ttsModel: "tts-1",
    language: "ko",
};
export function loadConfig(path) {
    const target = path ?? new URL(".siren.json", import.meta.url).pathname;
    if (!existsSync(target))
        return { ...DEFAULTS };
    try {
        return { ...DEFAULTS, ...JSON.parse(readFileSync(target, "utf-8")) };
    }
    catch {
        return { ...DEFAULTS };
    }
}
