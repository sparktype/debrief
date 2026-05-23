// LLM 기반 텍스트 요약기 — 사내 OpenAI endpoint 사용, 실패 시 규칙 기반 폴백
import OpenAI from "openai";

const OPENAI_BASE_URL =
  process.env.OPENAI_BASE_URL ?? "https://h-chat-api.autoever.com/openai/v1";

const SYSTEM_PROMPT =
  "주어진 텍스트의 핵심 결론이나 중요한 내용을 1~3문장으로 요약하세요. " +
  "코드·마크다운 기호 없이 자연스러운 한국어 평문으로 작성합니다.";

function makeClient(): OpenAI {
  return new OpenAI({
    apiKey: process.env.OPENAI_API_KEY ?? "",
    baseURL: OPENAI_BASE_URL,
  });
}

function stripMarkdown(text: string): string {
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

function fallback(text: string, sentenceCount = 3): string {
  const cleaned = stripMarkdown(text);
  if (!cleaned) return "";
  const sentences = cleaned
    .split(/(?<=[.!?。])\s*/)
    .map((s) => s.trim())
    .filter((s) => s.length > 1);
  if (sentences.length === 0) return cleaned;
  return sentences.slice(-sentenceCount).join(" ");
}

export async function extractSummary(text: string, model = "gpt-5.4"): Promise<string> {
  if (!text.trim()) return "";
  try {
    const client = makeClient();
    const resp = await client.chat.completions.create({
      model,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: stripMarkdown(text) },
      ],
      max_tokens: 200,
      temperature: 0.3,
    });
    return resp.choices[0]?.message?.content?.trim() || fallback(text);
  } catch {
    return fallback(text);
  }
}
