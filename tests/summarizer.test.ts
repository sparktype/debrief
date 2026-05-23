import { describe, it, expect } from "vitest";
import { extractSummary } from "../src/summarizer.js";

describe("extractSummary", () => {
  it("마지막 3문장 반환", () => {
    const text = "첫째다. 둘째다. 셋째다. 넷째다. 다섯째다.";
    const result = extractSummary(text, 3);
    expect(result).toContain("셋째다");
    expect(result).toContain("넷째다");
    expect(result).toContain("다섯째다");
    expect(result).not.toContain("첫째다");
  });

  it("코드 블록을 제거하고 추출", () => {
    const text = "결론이다.\n```js\nconst x = 1;\n```\n끝이다.";
    const result = extractSummary(text, 2);
    expect(result).not.toContain("const x");
    expect(result).toContain("끝이다");
  });

  it("문장이 N개 미만이면 전체 반환", () => {
    const text = "짧은 텍스트다.";
    const result = extractSummary(text, 3);
    expect(result).toBe("짧은 텍스트다.");
  });

  it("빈 문자열은 빈 문자열 반환", () => {
    expect(extractSummary("", 3)).toBe("");
  });
});
