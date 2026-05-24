// 사용자 설정 파일 로더 및 기본값 관리
import { readFileSync, existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = join(__dirname, "..", ".siren.json");
const DEFAULTS = {
    autoSpeak: true,
    minChars: 50,
    voice: "Sohee",
    summaryModel: "gpt-5.4",
    ttsSpeed: 1.2,
    ttsInstruct: "밝고 활기차게 말해주세요",
    skillCooldownMinutes: 30,
    supertonicPort: 7788,
    edgeTimeoutMs: 10000,
    supertonicTimeoutMs: 20000,
};
export function loadConfig(path) {
    const target = path ?? DEFAULT_CONFIG_PATH;
    if (!existsSync(target))
        return { ...DEFAULTS };
    try {
        return { ...DEFAULTS, ...JSON.parse(readFileSync(target, "utf-8")) };
    }
    catch {
        return { ...DEFAULTS };
    }
}
