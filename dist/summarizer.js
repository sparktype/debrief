// 텍스트에서 핵심 문장 추출 (Phase 1: 규칙 기반)
export function extractSummary(text, sentenceCount = 3) {
    if (!text.trim())
        return "";
    const cleaned = text
        .replace(/```[\s\S]*?```/g, "") // 코드 블록 제거
        .replace(/`[^`]+`/g, "") // 인라인 코드 제거
        .replace(/#{1,6} .+/gm, "") // 마크다운 헤더 제거
        .replace(/\n+/g, " ")
        .trim();
    const sentences = cleaned
        .split(/(?<=[.!?。])\s*/)
        .map((s) => s.trim())
        .filter((s) => s.length > 1);
    if (sentences.length === 0)
        return cleaned;
    return sentences.slice(-sentenceCount).join(" ");
}
