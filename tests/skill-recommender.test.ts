import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("openai");

import {
  parseCatalog,
  isInCooldown,
  parseRecommendation,
  readRecentTranscripts,
} from "../src/skill-recommender.js";

describe("parseCatalog", () => {
  it("올바른 JSON이면 배열 반환", () => {
    const result = parseCatalog('[{"skill":"plan","description":"계획"}]');
    expect(result).toEqual([{ skill: "plan", description: "계획" }]);
  });

  it("빈 문자열이면 빈 배열 반환", () => {
    expect(parseCatalog("")).toEqual([]);
  });

  it("잘못된 JSON이면 빈 배열 반환", () => {
    expect(parseCatalog("not json")).toEqual([]);
  });
});

describe("parseRecommendation", () => {
  const catalog = [
    { skill: "plan", description: "계획" },
    { skill: "code-review", description: "리뷰" },
  ];

  it("유효한 JSON + catalog에 있는 스킬이면 반환", () => {
    const rec = parseRecommendation('{"skill":"plan","reason":"계획이 필요합니다"}', catalog);
    expect(rec).toEqual({ skill: "plan", reason: "계획이 필요합니다" });
  });

  it("catalog에 없는 스킬이면 null 반환", () => {
    const rec = parseRecommendation('{"skill":"unknown","reason":"..."}', catalog);
    expect(rec).toBeNull();
  });

  it("JSON이 아니면 null 반환", () => {
    const rec = parseRecommendation("I recommend plan skill", catalog);
    expect(rec).toBeNull();
  });

  it("skill 필드 없으면 null 반환", () => {
    const rec = parseRecommendation('{"reason":"no skill field"}', catalog);
    expect(rec).toBeNull();
  });
});

describe("isInCooldown", () => {
  it("마지막 추천이 30분 이내면 true", () => {
    const recentTime = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    const cooldowns = { plan: recentTime };
    expect(isInCooldown("plan", cooldowns, 30)).toBe(true);
  });

  it("마지막 추천이 30분 초과면 false", () => {
    const oldTime = new Date(Date.now() - 35 * 60 * 1000).toISOString();
    const cooldowns = { plan: oldTime };
    expect(isInCooldown("plan", cooldowns, 30)).toBe(false);
  });

  it("쿨다운 기록 없으면 false", () => {
    expect(isInCooldown("plan", {}, 30)).toBe(false);
  });
});

describe("readRecentTranscripts", () => {
  it("존재하지 않는 디렉토리면 빈 문자열 반환", () => {
    const result = readRecentTranscripts("/nonexistent/path/transcripts", 3, 50);
    expect(result).toBe("");
  });
});
