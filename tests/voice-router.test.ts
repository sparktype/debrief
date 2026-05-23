import { describe, it, expect } from "vitest";
import { writeFileSync, unlinkSync } from "fs";
import { resolveVoice, loadVoiceMap, type VoiceMap } from "../src/voice-router.js";

const FIXTURE: VoiceMap = {
  supertonic: { lang: "ko" },
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
    expect(map.supertonic.lang).toBe("ko");
  });
});

describe("loadVoiceMap — port 필드 없는 voice-map 허용", () => {
  it("supertonic에 port 없어도 loadVoiceMap이 정상 반환", () => {
    // voice-map.json에서 port를 제거한 구조
    const noPortJson = JSON.stringify({
      supertonic: { lang: "ko" },
      voices: { default: "F1" },
      categories: {},
    });
    const tmp = `/tmp/test-voice-map-${Date.now()}.json`;
    writeFileSync(tmp, noPortJson, "utf-8");
    const map = loadVoiceMap(tmp);
    expect(map.supertonic.lang).toBe("ko");
    // port 필드가 타입에 없으므로 접근 자체가 TS 컴파일 오류여야 함
    // (런타임 테스트: map.supertonic에 port 키가 없음)
    expect((map.supertonic as any).port).toBeUndefined();
    unlinkSync(tmp);
  });
});
