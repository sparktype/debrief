// LLM 기반 텍스트 요약기 — 사내 HUB OpenAI endpoint 사용, 실패 시 규칙 기반 폴백
import { makeHubClient } from "./llm-client.js";
const SYSTEM_PROMPT = "주어진 텍스트의 핵심 결론이나 중요한 내용을 1~3문장으로 요약하세요. " +
    "코드·마크다운 기호 없이 자연스러운 한국어 평문으로 작성합니다.";
function stripMarkdown(text) {
    return text
        .replace(/```[\s\S]*?```/g, "[코드 생략]")
        .replace(/`[^`]+`/g, "")
        .replace(/^\|.+$/gm, "")
        .replace(/#{1,6} (.+)/gm, "$1")
        .replace(/^[-*]{3,}$/gm, "")
        .replace(/\*{1,3}([^*\n]+)\*{1,3}/g, "$1")
        .replace(/_([^_\n]+)_/g, "$1")
        .replace(/\n+/g, " ")
        .trim();
}
function fallback(text, sentenceCount = 3) {
    const cleaned = stripMarkdown(text);
    if (!cleaned)
        return "";
    const sentences = cleaned
        .split(/(?<=[.!?。])\s*/)
        .map((s) => s.trim())
        .filter((s) => s.length > 1);
    if (sentences.length === 0)
        return cleaned;
    return sentences.slice(-sentenceCount).join(" ");
}
// 발음할 수 없는 문자 제거 — 한글·영문·숫자·기본 구두점만 허용
function sanitizeForSpeech(text) {
    return text
        .replace(/[^\p{L}\p{N}\s,.。:]/gu, " ")
        .replace(/\s+/g, " ")
        .trim();
}
const ONE_LINER_PROMPT = "작업 결과를 한 문장(25자 이내)으로 요약하세요. 마침표·특수기호 없이, 간결하게.";
export async function extractOneLiner(text, model = "gpt-5.4") {
    if (!text.trim())
        return "";
    try {
        const client = makeHubClient();
        const resp = await client.chat.completions.create({
            model,
            messages: [
                { role: "system", content: ONE_LINER_PROMPT },
                { role: "user", content: stripMarkdown(text).slice(0, 2000) },
            ],
            max_completion_tokens: 60,
            temperature: 0.3,
        });
        const raw = resp.choices[0]?.message?.content?.trim() || fallback(text, 1);
        return sanitizeForSpeech(raw);
    }
    catch {
        return sanitizeForSpeech(fallback(text, 1));
    }
}
export async function extractSummary(text, model = "gpt-5.4") {
    if (!text.trim())
        return "";
    try {
        const client = makeHubClient();
        const resp = await client.chat.completions.create({
            model,
            messages: [
                { role: "system", content: SYSTEM_PROMPT },
                { role: "user", content: stripMarkdown(text) },
            ],
            max_completion_tokens: 200,
            temperature: 0.3,
        });
        return resp.choices[0]?.message?.content?.trim() || fallback(text);
    }
    catch {
        return fallback(text);
    }
}
