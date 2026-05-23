import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("openai", () => {
  const mockCreate = vi.fn().mockResolvedValue({
    choices: [{ message: { content: "LLM 요약 결과입니다." } }],
  });
  return {
    default: vi.fn().mockImplementation(() => ({
      chat: { completions: { create: mockCreate } },
    })),
    __mockCreate: mockCreate,
  };
});

import { extractSummary } from "../src/summarizer.js";
import OpenAI from "openai";

// 각 테스트 시작 전 mock 호출 이력 초기화
beforeEach(() => {
  vi.clearAllMocks();
});

function getMockCreate() {
  const instance = vi.mocked(OpenAI).mock.results[0]?.value;
  if (!instance) throw new Error("OpenAI mock 인스턴스 생성 실패 — extractSummary 호출 후 사용해야 합니다");
  return instance.chat.completions.create as ReturnType<typeof vi.fn>;
}

describe("extractSummary — LLM 경로", () => {
  it("LLM 응답 내용을 반환", async () => {
    const result = await extractSummary("이것은 긴 텍스트입니다. 여러 내용이 담겨 있습니다.");
    expect(result).toBe("LLM 요약 결과입니다.");
  });

  it("빈 문자열은 LLM 미호출, 빈 문자열 반환", async () => {
    const result = await extractSummary("   ");
    expect(result).toBe("");
    expect(OpenAI).not.toHaveBeenCalled();
  });

  it("model 파라미터를 LLM에 전달", async () => {
    await extractSummary("텍스트", "gpt-5.4");
    const create = getMockCreate();
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({ model: "gpt-5.4" }),
    );
  });

  it("LLM 빈 content → 규칙 기반 폴백 반환", async () => {
    vi.mocked(OpenAI).mockImplementationOnce(() => ({
      chat: {
        completions: {
          create: vi.fn().mockResolvedValue({
            choices: [{ message: { content: "" } }],
          }),
        },
      },
    }) as any);
    const result = await extractSummary("첫째다. 둘째다. 셋째다.");
    expect(result).toBeTruthy();
  });
});

describe("extractSummary — 폴백 경로", () => {
  it("LLM 네트워크 오류 시 마지막 3문장 반환", async () => {
    vi.mocked(OpenAI).mockImplementationOnce(() => ({
      chat: {
        completions: {
          create: vi.fn().mockRejectedValue(new Error("ECONNREFUSED")),
        },
      },
    }) as any);
    const result = await extractSummary("첫째다. 둘째다. 셋째다. 넷째다. 다섯째다.");
    expect(result).toContain("셋째다");
    expect(result).toContain("다섯째다");
    expect(result).not.toContain("첫째다");
  });

  it("마크다운 제거 후 폴백", async () => {
    vi.mocked(OpenAI).mockImplementationOnce(() => ({
      chat: {
        completions: {
          create: vi.fn().mockRejectedValue(new Error("fail")),
        },
      },
    }) as any);
    const result = await extractSummary("결론이다.\n```js\nconst x=1;\n```\n끝이다.");
    expect(result).not.toContain("const x");
  });
});
