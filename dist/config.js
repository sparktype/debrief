// 사용자 설정 파일 로더 및 기본값 관리
import { readFileSync, existsSync } from "fs";
const DEFAULTS = {
    autoSpeak: true,
    minChars: 200,
    voice: "Sohee",
    summaryModel: "gpt-5.4",
    ttsModel: "tts-1",
    language: "ko",
    ttsSpeed: 1.2,
    ttsInstruct: "밝고 활기차게 말해주세요",
    skillCooldownMinutes: 30,
    supertonicPort: 7788,
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
