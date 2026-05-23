import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("openai");
vi.mock("fs");

import {
  parseCatalog,
  isInCooldown,
  parseRecommendation,
  readRecentTranscripts,
  _resetTranscriptCache,
} from "../src/skill-recommender.js";
import * as fs from "fs";

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

describe("readRecentTranscripts — 기본 동작", () => {
  beforeEach(() => {
    vi.mocked(fs.existsSync).mockReturnValue(false);
    _resetTranscriptCache();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    _resetTranscriptCache();
  });

  it("존재하지 않는 디렉토리면 빈 문자열 반환", () => {
    vi.mocked(fs.existsSync).mockReturnValue(false);
    const result = readRecentTranscripts("/nonexistent/path/transcripts", 3, 50);
    expect(result).toBe("");
  });
});

describe("readRecentTranscripts — TTL 캐시", () => {
  const fakeDir = "/fake/transcripts";

  beforeEach(() => {
    _resetTranscriptCache();
    // 디렉토리 존재, 파일 목록 반환
    vi.mocked(fs.existsSync).mockReturnValue(true);
    vi.mocked(fs.readdirSync).mockReturnValue(["session.jsonl"] as unknown as fs.Dirent[]);
    vi.mocked(fs.statSync).mockReturnValue({ mtimeMs: Date.now() } as fs.Stats);
    vi.mocked(fs.readFileSync).mockReturnValue('{"type":"user","content":"hello"}\n');
  });

  afterEach(() => {
    vi.restoreAllMocks();
    _resetTranscriptCache();
  });

  it("같은 경로 두 번 호출 시 readFileSync 1회만 호출", () => {
    readRecentTranscripts(fakeDir, 3, 50);
    readRecentTranscripts(fakeDir, 3, 50);

    // 파일 내용 읽기는 첫 번째 호출에만 발생해야 함
    expect(vi.mocked(fs.readFileSync)).toHaveBeenCalledTimes(1);
  });

  it("TTL 초과 후 재호출 시 readFileSync 2회 호출", () => {
    const now = Date.now();
    // 첫 번째 호출: now 반환 (캐시 저장), 이후 호출: now + 61초 반환 (TTL 초과 판정)
    const dateSpy = vi.spyOn(Date, "now")
      .mockReturnValueOnce(now)  // 첫 번째 readRecentTranscripts 내부 캐시 저장 시
      .mockReturnValue(now + 61_000); // 두 번째 readRecentTranscripts 내부 TTL 비교 + 캐시 저장 시

    readRecentTranscripts(fakeDir, 3, 50);
    readRecentTranscripts(fakeDir, 3, 50);

    expect(vi.mocked(fs.readFileSync)).toHaveBeenCalledTimes(2);
    dateSpy.mockRestore();
  });

  it("다른 경로는 각각 독립적으로 캐시됨", () => {
    const fakeDir2 = "/fake/other-transcripts";
    vi.mocked(fs.existsSync).mockReturnValue(true);
    vi.mocked(fs.readdirSync).mockReturnValue(["session.jsonl"] as unknown as fs.Dirent[]);

    readRecentTranscripts(fakeDir, 3, 50);
    readRecentTranscripts(fakeDir2, 3, 50);

    // 두 경로 각각 readFileSync 1회씩 → 총 2회
    expect(vi.mocked(fs.readFileSync)).toHaveBeenCalledTimes(2);
  });
});
