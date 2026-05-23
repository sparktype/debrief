// HMG Hub LLM 클라이언트 공통 모듈
import OpenAI from "openai";

let _cachedClient: OpenAI | null = null;
let _cachedEnvKey = "";

export function makeHubClient(): OpenAI {
  // 환경변수 변경 감지 키 — 변경 시 캐시 무효화
  const envKey = `${process.env.HUB_BASE_URL}|${process.env.HUB_API_KEY}|${process.env.HUB_PROJECT_ID}`;
  if (!_cachedClient || envKey !== _cachedEnvKey) {
    _cachedClient = new OpenAI({
      baseURL: process.env.HUB_BASE_URL ?? "",
      apiKey: process.env.HUB_API_KEY ?? "",
      defaultHeaders: process.env.HUB_PROJECT_ID
        ? { "X-Project-Id": process.env.HUB_PROJECT_ID }
        : {},
    });
    _cachedEnvKey = envKey;
  }
  return _cachedClient;
}

/** 테스트 전용 — 싱글톤 캐시 초기화 */
export function _resetHubClient(): void {
  _cachedClient = null;
  _cachedEnvKey = "";
}

export function getDefaultModel(): string {
  return "gpt-5.4";
}
