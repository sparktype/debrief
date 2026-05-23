// 텍스트에서 요약·결론 문장을 추출 (Phase 1: 규칙 기반)

const CONCLUSION_PATTERNS = [
  /요약(?:하면|:)\s*.+/,
  /결론(?:적으로|은|:)\s*.+/,
  /정리하면\s*.+/,
  /한마디로\s*.+/,
  /핵심(?:은|:)\s*.+/,
  /즉,\s*.+/,
  /in summary[,:]?\s*.+/i,
  /to summarize[,:]?\s*.+/i,
  /in conclusion[,:]?\s*.+/i,
];

export function extractSummary(text: string, sentenceCount = 3): string {
  if (!text.trim()) return "";

  const cleaned = text
    .replace(/```[\s\S]*?```/g, "")           // 코드 블록
    .replace(/`[^`]+`/g, "")                    // 인라인 코드
    .replace(/^\|.+$/gm, "")                   // 테이블 행
    .replace(/#{1,6} .+/gm, "")                 // 마크다운 헤더
    .replace(/^[-*]{3,}$/gm, "")                // 수평선
    .replace(/\*{1,3}([^*\n]+)\*{1,3}/g, "$1") // 볼드·이탤릭
    .replace(/_([^_\n]+)_/g, "$1")             // 언더스코어 이탤릭
    .replace(/\n+/g, " ")
    .trim();

  for (const pattern of CONCLUSION_PATTERNS) {
    const match = cleaned.match(pattern);
    if (match) {
      return match[0].trim();
    }
  }

  const sentences = cleaned
    .split(/(?<=[.!?。])\s*/)
    .map((s) => s.trim())
    .filter((s) => s.length > 1);

  if (sentences.length === 0) return cleaned;
  return sentences.slice(-sentenceCount).join(" ");
}
