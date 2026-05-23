// LLM 클라이언트 싱글톤 단위 테스트
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { makeHubClient, _resetHubClient } from "../src/llm-client.js";

describe("makeHubClient — 싱글톤", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    _resetHubClient();
    process.env.HUB_BASE_URL = "https://test.hub/api";
    process.env.HUB_API_KEY = "test-key";
    process.env.HUB_PROJECT_ID = "proj-1";
  });

  afterEach(() => {
    process.env = { ...originalEnv };
    _resetHubClient();
  });

  it("두 번 호출 시 동일 인스턴스 반환", () => {
    const a = makeHubClient();
    const b = makeHubClient();
    expect(a).toBe(b);
  });

  it("환경변수 변경 후 재호출 시 새 인스턴스 반환", () => {
    const a = makeHubClient();
    process.env.HUB_API_KEY = "changed-key";
    const b = makeHubClient();
    expect(a).not.toBe(b);
  });
});
