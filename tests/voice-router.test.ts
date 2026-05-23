import { describe, it, expect } from "vitest";
import { resolveVoice, loadVoiceMap, type VoiceMap } from "../src/voice-router.js";

const FIXTURE: VoiceMap = {
  supertonic: { port: 7788, lang: "ko" },
  voices: {
    reviewer: "M2",
    planner: "M1",
    builder: "M4",
    explorer: "F3",
    default: "F1",
  },
  categories: {
    reviewer: ["code-reviewer", "python-reviewer"],
    planner: ["planner", "architect"],
    builder: ["build-error-resolver"],
    explorer: ["Explore", "general-purpose"],
  },
};

describe("resolveVoice", () => {
  it("알려진 에이전트를 카테고리 voice로 변환한다", () => {
    expect(resolveVoice("code-reviewer", FIXTURE)).toBe("M2");
    expect(resolveVoice("planner", FIXTURE)).toBe("M1");
    expect(resolveVoice("build-error-resolver", FIXTURE)).toBe("M4");
    expect(resolveVoice("Explore", FIXTURE)).toBe("F3");
  });

  it("매핑 없는 에이전트는 default voice를 반환한다", () => {
    expect(resolveVoice("unknown-agent", FIXTURE)).toBe("F1");
    expect(resolveVoice("", FIXTURE)).toBe("F1");
  });

  it("voices에 카테고리가 없으면 default로 폴백한다", () => {
    const map: VoiceMap = {
      ...FIXTURE,
      voices: { default: "F1" },
    };
    expect(resolveVoice("code-reviewer", map)).toBe("F1");
  });

  it("default voice가 없으면 F1을 하드코딩 폴백으로 반환한다", () => {
    const map: VoiceMap = {
      ...FIXTURE,
      voices: {},
    };
    expect(resolveVoice("unknown", map)).toBe("F1");
  });
});

describe("loadVoiceMap", () => {
  it("존재하지 않는 경로에서도 기본값을 반환한다", () => {
    const map = loadVoiceMap("/nonexistent/voice-map.json");
    expect(map.voices.default).toBe("F1");
    expect(map.supertonic.port).toBe(7788);
  });
});
