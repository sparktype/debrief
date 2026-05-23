// HMG Hub LLM 클라이언트 공통 모듈
import OpenAI from "openai";

export function makeHubClient(): OpenAI {
  return new OpenAI({
    baseURL: process.env.HUB_BASE_URL ?? "",
    apiKey: process.env.HUB_API_KEY ?? "",
    defaultHeaders: process.env.HUB_PROJECT_ID
      ? { "X-Project-Id": process.env.HUB_PROJECT_ID }
      : {},
  });
}

export function getDefaultModel(): string {
  return "gpt-5.4";
}
