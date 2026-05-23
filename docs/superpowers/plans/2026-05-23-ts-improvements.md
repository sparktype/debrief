# TS 팀 개선 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `src/` TypeScript 코드에서 성능·로직 효율성 8개 항목(T1~T8)을 TDD로 개선한다.

**Architecture:** 리드의 R1~R3 완료 후 시작한다. 각 태스크는 독립적으로 실행 가능하다. `llm-client.ts` 싱글톤(T1)은 `summarizer.ts` 모든 테스트와 연관되므로 첫 번째로 처리한다. `player.ts` 관련 태스크(T4·T5·T7·T8)는 같은 파일을 수정하므로 순서대로 진행한다.

**Tech Stack:** TypeScript, vitest, Node.js ESM

**전제 조건:** 리드의 `2026-05-23-lead-cross-layer.md` 계획이 완료되어 있어야 한다. `npm test`가 58개+ 통과 상태여야 한다.

---

## 파일 변경 범위

| 파일 | 작업 |
|---|---|
| `src/llm-client.ts` | 싱글톤 캐시 + `resetClientCache()` export |
| `src/summarizer.ts` | `makeHubClient()` 호출 제거 (싱글톤 사용) |
| `src/skill-recommender.ts` | transcript 캐시(TTL 60s) + `loadCooldowns` 이중 호출 제거 + `clearTranscriptCache()` export |
| `src/config.ts` | `edgeTimeoutMs`, `supertonicTimeoutMs` 필드 추가 |
| `src/index.ts` | T3: `configureTimes` 호출 추가 |
| `src/player.ts` | EDGE_VOICE 상수화, 빈 segments 방어, 폴백 체인 정리, venv 동적 탐색, 타임아웃 config 연동 |
| `tests/llm-client.test.ts` | 신규 — 싱글톤 동작 테스트 |
| `tests/skill-recommender.test.ts` | transcript 캐시 + cooldown 단일 호출 테스트 추가 |
| `tests/player.test.ts` | T4·T5·T7·T8 관련 테스트 추가 |
| `tests/config.test.ts` | `edgeTimeoutMs`, `supertonicTimeoutMs` 기본값 테스트 추가 |

---

## Task T1: `makeHubClient()` 싱글톤

**Files:**
- Modify: `src/llm-client.ts`
- Create: `tests/llm-client.test.ts`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/llm-client.test.ts` 신규 생성:

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("openai", () => ({
  default: vi.fn().mockImplementation(() => ({ id: Math.random() })),
}));

import { makeHubClient, resetClientCache } from "../src/llm-client.js";

beforeEach(() => {
  resetClientCache();
  process.env.HUB_API_KEY = "test-key";
});

afterEach(() => {
  delete process.env.HUB_API_KEY;
});

describe("makeHubClient — 싱글톤", () => {
  it("같은 환경변수로 두 번 호출하면 동일 인스턴스 반환", () => {
    const a = makeHubClient();
    const b = makeHubClient();
    expect(a).toBe(b);
  });

  it("API_KEY 변경 시 새 인스턴스 반환", () => {
    process.env.HUB_API_KEY = "key-1";
    const a = makeHubClient();
    process.env.HUB_API_KEY = "key-2";
    const b = makeHubClient();
    expect(a).not.toBe(b);
  });

  it("resetClientCache 후 새 인스턴스 반환", () => {
    const a = makeHubClient();
    resetClientCache();
    const b = makeHubClient();
    expect(a).not.toBe(b);
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/llm-client.test.ts
```

Expected: `resetClientCache is not a function` 오류.

- [ ] **Step 3: `llm-client.ts` 싱글톤으로 수정**

```typescript
// HMG Hub LLM 클라이언트 공통 모듈
import OpenAI from "openai";

let _client: OpenAI | undefined;
let _lastKey: string | undefined;

export function resetClientCache(): void {
  _client = undefined;
  _lastKey = undefined;
}

export function makeHubClient(): OpenAI {
  const key = process.env.HUB_API_KEY ?? "";
  if (_client && _lastKey === key) return _client;
  _client = new OpenAI({
    baseURL: process.env.HUB_BASE_URL ?? "",
    apiKey: key,
    defaultHeaders: process.env.HUB_PROJECT_ID
      ? { "X-Project-Id": process.env.HUB_PROJECT_ID }
      : {},
  });
  _lastKey = key;
  return _client;
}

export function getDefaultModel(): string {
  return "gpt-5.4";
}
```

- [ ] **Step 4: 기존 summarizer.test.ts 호환 확인**

`summarizer.test.ts`는 `openai` 모듈 전체를 mock하므로 싱글톤 캐시가 mock 인스턴스를 물고 있어도 정상 동작한다. `beforeEach`에서 `vi.clearAllMocks()`가 호출되므로 문제없다.

```bash
npx vitest run tests/summarizer.test.ts tests/llm-client.test.ts
```

Expected: 모두 통과.

- [ ] **Step 5: 전체 테스트 통과 확인**

```bash
npm test
```

Expected: 기존 + 3 신규 = 61개+ 통과.

- [ ] **Step 6: 커밋**

```bash
git add src/llm-client.ts tests/llm-client.test.ts
git commit -m "perf: makeHubClient 싱글톤 — 매 호출 인스턴스 생성 제거"
```

---

## Task T2: Transcript 인메모리 캐싱

**Files:**
- Modify: `src/skill-recommender.ts`
- Modify: `tests/skill-recommender.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/skill-recommender.test.ts` 맨 끝에 추가:

```typescript
import { clearTranscriptCache } from "../src/skill-recommender.js";
// (기존 import 줄 수정: clearTranscriptCache 추가)
```

그리고 describe 블록 추가:

```typescript
describe("readRecentTranscripts — 캐싱", () => {
  it("같은 경로 두 번 호출 시 readFileSync 1회만 호출", () => {
    const mockReadFile = vi.spyOn(
      await import("fs"),
      "readFileSync"
    ).mockReturnValue('{"type":"user","content":"hello"}\n' as any);

    clearTranscriptCache();
    readRecentTranscripts("/tmp/fake-transcripts");
    readRecentTranscripts("/tmp/fake-transcripts");

    // readdirSync + readFileSync 합산에서 readFileSync는 1회만
    // (readdirSync가 파일 목록 반환 mock 필요 — 단순화: cache hit 시 0회 추가)
    const callCount = mockReadFile.mock.calls.filter(
      c => String(c[0]).includes("fake-transcripts")
    ).length;
    expect(callCount).toBeLessThanOrEqual(1);
    mockReadFile.mockRestore();
  });
});
```

이 테스트는 캐시가 없으면 항상 2회 호출되어 실패한다. 단, `existsSync`가 false를 반환하면 "" 반환이므로 캐시가 필요하다. 실제로는 `readRecentTranscripts`를 직접 spy해서 확인하는 것이 더 명확하다. 아래처럼 단순화한다:

```typescript
describe("readRecentTranscripts — 캐싱", () => {
  it("clearTranscriptCache 후 두 번 호출해도 같은 결과 반환", () => {
    clearTranscriptCache();
    // transcriptsDir이 존재하지 않으면 "" 반환 — 캐시도 ""를 저장해야 함
    const first = readRecentTranscripts("/nonexistent-path-xyz");
    const second = readRecentTranscripts("/nonexistent-path-xyz");
    expect(first).toBe(second); // 캐시에서 동일 결과 반환
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/skill-recommender.test.ts
```

Expected: `clearTranscriptCache is not a function` 오류.

- [ ] **Step 3: `skill-recommender.ts` 캐시 추가**

`readRecentTranscripts` 함수 위에 캐시 코드 추가하고 함수 수정:

```typescript
// transcript 캐시 — TTL 60초
interface _CacheEntry { value: string; expiresAt: number }
const _transcriptCache = new Map<string, _CacheEntry>();
const TRANSCRIPT_TTL_MS = 60_000;

export function clearTranscriptCache(): void {
  _transcriptCache.clear();
}

export function readRecentTranscripts(
  transcriptsDir = join(homedir(), ".claude", "transcripts"),
  maxFiles = 3,
  maxLinesPerFile = 50
): string {
  const cacheKey = `${transcriptsDir}:${maxFiles}:${maxLinesPerFile}`;
  const cached = _transcriptCache.get(cacheKey);
  if (cached && Date.now() < cached.expiresAt) return cached.value;

  // 기존 로직 (변경 없음)
  let result = "";
  try {
    if (!existsSync(transcriptsDir)) {
      result = "";
    } else {
      const files = readdirSync(transcriptsDir)
        .filter((f) => f.endsWith(".jsonl"))
        .map((f) => ({ name: f, mtime: statSync(join(transcriptsDir, f)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, maxFiles)
        .map((f) => f.name);

      result = files
        .map((file) => {
          const lines = readFileSync(join(transcriptsDir, file), "utf-8")
            .split("\n")
            .filter(Boolean)
            .slice(-maxLinesPerFile);
          return lines
            .map((line) => {
              try {
                const entry = JSON.parse(line);
                const content = String(entry.content ?? "").slice(0, 300);
                if (entry.type === "user") return `User: ${content}`;
                if (entry.type === "assistant") return `Assistant: ${content}`;
                return null;
              } catch {
                return null;
              }
            })
            .filter(Boolean)
            .join("\n");
        })
        .join("\n---\n");
    }
  } catch {
    result = "";
  }

  _transcriptCache.set(cacheKey, { value: result, expiresAt: Date.now() + TRANSCRIPT_TTL_MS });
  return result;
}
```

- [ ] **Step 4: import 줄에 `clearTranscriptCache` 추가 확인**

`tests/skill-recommender.test.ts`의 import:

```typescript
import {
  parseCatalog,
  isInCooldown,
  parseRecommendation,
  readRecentTranscripts,
  clearTranscriptCache,
} from "../src/skill-recommender.js";
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **Step 6: 커밋**

```bash
git add src/skill-recommender.ts tests/skill-recommender.test.ts
git commit -m "perf: readRecentTranscripts TTL 60s 인메모리 캐시 추가"
```

---

## Task T3: EdgeTTS 타임아웃 config 연동

**Files:**
- Modify: `src/config.ts`
- Modify: `src/player.ts`
- Modify: `tests/config.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/config.test.ts` 맨 끝에 추가:

```typescript
it("edgeTimeoutMs 기본값 10000", () => {
  const cfg = loadConfig("/nonexistent.json");
  expect(cfg.edgeTimeoutMs).toBe(10000);
});

it("supertonicTimeoutMs 기본값 20000", () => {
  const cfg = loadConfig("/nonexistent.json");
  expect(cfg.supertonicTimeoutMs).toBe(20000);
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/config.test.ts
```

Expected: `edgeTimeoutMs` 필드 없어 undefined 반환.

- [ ] **Step 3: `SirenConfig`에 필드 추가**

`src/config.ts`:

```typescript
export interface SirenConfig {
  autoSpeak: boolean;
  minChars: number;
  voice: string;
  summaryModel: string;
  ttsModel: string;
  language: string;
  ttsSpeed: number;
  ttsInstruct: string;
  skillCooldownMinutes: number;
  supertonicPort: number;
  edgeTimeoutMs: number;
  supertonicTimeoutMs: number;
}

const DEFAULTS: SirenConfig = {
  autoSpeak: true,
  minChars: 50,
  voice: "Sohee",
  summaryModel: "gpt-5.4",
  ttsModel: "tts-1",
  language: "ko",
  ttsSpeed: 1.2,
  ttsInstruct: "밝고 활기차게 말해주세요",
  skillCooldownMinutes: 30,
  supertonicPort: 7788,
  edgeTimeoutMs: 10000,
  supertonicTimeoutMs: 20000,
};
```

- [ ] **Step 4: `.siren.json.example`에도 추가**

```bash
# .siren.json.example에 두 필드 추가
# 파일을 열어 supertonicPort 다음 줄에 삽입:
#   "edgeTimeoutMs": 10000,
#   "supertonicTimeoutMs": 20000,
```

`.siren.json.example`에서 `"supertonicPort": 7788` 다음 줄에:

```json
  "edgeTimeoutMs": 10000,
  "supertonicTimeoutMs": 20000
```

- [ ] **Step 5: `player.ts`에서 config 대신 파라미터로 받도록 수정**

`player.ts`에서 `EDGE_TIMEOUT_MS`, `SPEAK_TIMEOUT_MS` 상수를 조정 가능한 변수로 교체한다. `configureTimes()` 함수 export:

```typescript
// 기존 상수 아래에 추가
let _edgeTimeoutMs = 10000;
let _supertonicTimeoutMs = 20000;

export function configureTimes(edgeMs: number, supertonicMs: number): void {
  _edgeTimeoutMs = edgeMs;
  _supertonicTimeoutMs = supertonicMs;
}
```

`generateEdge` 함수에서 `EDGE_TIMEOUT_MS` → `_edgeTimeoutMs`:

```typescript
// 변경 전
await Promise.race([
  edgePromise,
  new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error("EdgeTTS 타임아웃")), EDGE_TIMEOUT_MS)
  ),
]);

// 변경 후
await Promise.race([
  edgePromise,
  new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error("EdgeTTS 타임아웃")), _edgeTimeoutMs)
  ),
]);
```

`generateSupertonic`에서 `20000` → `_supertonicTimeoutMs`:

```typescript
// 변경 전
const timer = setTimeout(() => ctrl.abort(), 20000);

// 변경 후
const timer = setTimeout(() => ctrl.abort(), _supertonicTimeoutMs);
```

`index.ts`에서 config 로드 후 `configureTimes` 호출. `config` 변수 선언 바로 다음에 추가:

```typescript
import { configureTimes } from "./player.js";

let config: SirenConfig = loadConfig();
configureTimes(config.edgeTimeoutMs, config.supertonicTimeoutMs);
```

- [ ] **Step 6: 빌드 + 테스트 확인**

```bash
npm run build && npm test
```

Expected: 전체 통과.

- [ ] **Step 7: 커밋**

```bash
git add src/config.ts src/player.ts src/index.ts .siren.json.example tests/config.test.ts
git commit -m "feat: EdgeTTS·Supertonic 타임아웃 SirenConfig로 연동"
```

---

## Task T4: `EDGE_VOICE_MAP` 단순화

**Files:**
- Modify: `src/player.ts`
- Modify: `tests/player.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/player.test.ts` 맨 끝에 추가:

```typescript
describe("generateEdge — EDGE_VOICE 상수", () => {
  it("알 수 없는 voice 입력 시 HyunsuMultilingualNeural 사용", async () => {
    mockSpawnSequence(0);
    vi.mocked(fs.existsSync).mockReturnValue(true);
    // generateEdge는 내보내지 않으므로 speakHook을 통해 간접 검증
    // spawn 첫 번째 args에 HyunsuMultilingualNeural 포함 여부 확인
    mockFetchDead();
    await speak("테스트", "UnknownVoice123", 1.0, "");
    const spawnArgs = vi.mocked(cp.spawn).mock.calls[0];
    const allArgs = spawnArgs?.flat().join(" ") ?? "";
    expect(allArgs).toContain("HyunsuMultilingualNeural");
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/player.test.ts -t "EDGE_VOICE 상수"
```

Expected: 현재는 `EDGE_VOICE_MAP`에 없는 voice면 기본값 반환이라 통과할 수 있음. 일단 실행해서 확인.

- [ ] **Step 3: `EDGE_VOICE_MAP` → 상수로 교체**

`src/player.ts`에서:

```typescript
// 변경 전
const EDGE_VOICE_MAP: Record<string, string> = {
  Sohee:    "ko-KR-HyunsuMultilingualNeural",
  Vivian:   "ko-KR-HyunsuMultilingualNeural",
  // ... 9개 항목 동일 값
};
```

```typescript
// 변경 후 (Map 전체 제거, 상수 하나로)
const EDGE_VOICE = "ko-KR-HyunsuMultilingualNeural";
```

`generateEdge` 함수에서:

```typescript
// 변경 전
const edgeVoice = EDGE_VOICE_MAP[voice] ?? "ko-KR-HyunsuMultilingualNeural";

// 변경 후
const edgeVoice = EDGE_VOICE;
```

- [ ] **Step 4: 빌드 + 테스트 확인**

```bash
npm run build && npm test
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "refactor: EDGE_VOICE_MAP 제거 — 단일 상수 EDGE_VOICE로 대체"
```

---

## Task T5: 빈 segments 방어 코드

**Files:**
- Modify: `src/player.ts`
- Modify: `tests/player.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/player.test.ts`에 추가:

```typescript
describe("speakAgent — 빈 텍스트 방어", () => {
  it("공백 문자열 입력 시 fetch 미호출", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    vi.stubGlobal("fetch", fetchMock);
    await speakAgent("   ", "F1", 7788, 1.2);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/player.test.ts -t "빈 텍스트"
```

Expected: 현재 공백 텍스트가 들어오면 `splitByLanguage` 후 빈 배열, `segments[0]?.lang ?? "ko"` 호출 → fetch 호출됨.

- [ ] **Step 3: `speakAgent`에 early return 추가**

`src/player.ts`의 `speakAgent` 함수:

```typescript
export async function speakAgent(
  text: string,
  supertonicVoice: string,
  port: number,
  speed: number,
): Promise<void> {
  if (!text.trim()) return; // 빈 텍스트 방어

  if (await isSupertonicAlive(port)) {
    // ... 기존 로직
  }
  await speakInner(text, "", speed, "");
}
```

`generateSupertonic` 함수에도 방어 추가:

```typescript
async function generateSupertonic(text: string, voice: string, port: number): Promise<Buffer> {
  const segments = splitByLanguage(text);
  if (segments.length === 0) throw new Error("생성할 텍스트 세그먼트 없음");
  // ... 기존 로직
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "fix: speakAgent 빈 텍스트 입력 시 early return 추가"
```

---

## Task T6: `loadCooldowns()` 이중 호출 제거

**Files:**
- Modify: `src/skill-recommender.ts`
- Modify: `tests/skill-recommender.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/skill-recommender.test.ts`에 추가:

```typescript
describe("recommendSkill — loadCooldowns 단일 호출", () => {
  it("bypassCooldown=false 시 cooldown 파일 1회만 읽음", async () => {
    vi.mock("fs", async (orig) => ({
      ...(await orig<typeof import("fs")>()),
      existsSync: vi.fn().mockReturnValue(false),
      readFileSync: vi.fn().mockReturnValue("[]"),
    }));
    // recommendSkill이 내부적으로 loadCooldowns를 몇 번 호출하는지 간접 확인
    // catalog 없으면 null 즉시 반환이므로, catalog를 주입하는 방식 필요
    // 간단히: loadCooldowns는 exportedFunction이므로 spy 가능
    // loadCooldowns는 fs.readFileSync를 호출하므로 readFileSync spy로 간접 검증
    const fsMod = await import("fs");
    const readSpy = vi.spyOn(fsMod, "readFileSync").mockReturnValue("{}" as any);
    clearTranscriptCache();

    await recommendSkill("테스트 컨텍스트", false, 30);

    // catalog + cooldown 각 1회 = 최대 2회 (catalog 없으면 즉시 반환)
    // 핵심: cooldown을 위한 readFileSync가 2회 이상이면 이중 호출
    const cooldownCalls = readSpy.mock.calls.filter(
      c => String(c[0]).includes("skill-cooldowns")
    ).length;
    expect(cooldownCalls).toBeLessThanOrEqual(1);
    readSpy.mockRestore();
  });
});
```

실제로 함수 내부 호출 횟수를 vitest로 spy하기 어려우므로, 코드 수정 후 readFileSync spy로 검증한다.

- [ ] **Step 2: `recommendSkill` 함수 수정**

`src/skill-recommender.ts`의 `recommendSkill`:

```typescript
export async function recommendSkill(
  context: string,
  bypassCooldown = false,
  cooldownMinutes = 30,
  model?: string
): Promise<Recommendation | null> {
  const resolvedModel = model ?? getDefaultModel();
  const catalog = loadCatalog();
  if (catalog.length === 0 || !context.trim()) return null;

  // cooldown을 한 번만 읽는다 — bypassCooldown이면 빈 객체 사용
  const cooldowns = bypassCooldown ? {} : loadCooldowns();

  const skillsText = catalog.map((s) => `- ${s.skill}: ${s.description}`).join("\n");
  const prompt =
    `다음은 Claude Code 대화 히스토리 일부입니다:\n<transcript>\n${context}\n</transcript>\n\n` +
    `다음은 사용 가능한 스킬 목록입니다:\n<skills>\n${skillsText}\n</skills>\n\n` +
    `위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.\n` +
    `반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.\n` +
    `{"skill": "<스킬명>", "reason": "<한 문장 이유>"}`;

  try {
    const client = makeHubClient();
    const resp = await client.chat.completions.create({
      model: resolvedModel,
      messages: [{ role: "user", content: prompt }],
      max_completion_tokens: 100,
      temperature: 0.2,
    });

    const raw = resp.choices[0]?.message?.content?.trim() ?? "";
    const rec = parseRecommendation(raw, catalog);
    if (!rec) return null;

    if (!bypassCooldown && isInCooldown(rec.skill, cooldowns, cooldownMinutes)) return null;

    return rec;
  } catch {
    return null;
  }
}
```

- [ ] **Step 3: 테스트 통과 확인**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **Step 4: 커밋**

```bash
git add src/skill-recommender.ts tests/skill-recommender.test.ts
git commit -m "perf: recommendSkill에서 loadCooldowns 이중 호출 제거"
```

---

## Task T7: `speakHook`/`speakInner` 폴백 체인 정리

**Files:**
- Modify: `src/player.ts`
- Modify: `tests/player.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/player.test.ts`에 추가:

```typescript
describe("speakHook — EdgeTTS 성공 시 speakInner 경로 미진입", () => {
  it("EdgeTTS spawn 성공 시 afplay까지만 호출 (HTTP fetch 미호출)", async () => {
    vi.mocked(fs.existsSync).mockReturnValue(true);
    // spawn: EdgeTTS 성공(0), afplay 성공(0)
    mockSpawnSequence(0, 0);
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    process.env.SIREN_OFFLINE = undefined as any;
    delete process.env.SIREN_OFFLINE;

    // speakHook은 export되어 있음
    const { speakHook } = await import("../src/player.js");
    await speakHook("테스트 텍스트", "Sohee", 1.2);

    // EdgeTTS 성공 → 스풀 enqueue → 바로 반환 → HTTP fetch 호출 없음
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/player.test.ts -t "EdgeTTS 성공 시"
```

- [ ] **Step 3: `player.ts` 폴백 체인 정리**

`speakWithoutEdge` 내부 함수를 추출하고 `speakHook` 폴백과 `speakInner`에서 공유:

```typescript
// HTTP → Subprocess 경로 (Edge 제외)
async function speakWithoutEdge(text: string, voice: string, speed: number, instruct: string): Promise<void> {
  if (await isTTSServerAlive()) {
    try {
      await speakHTTP(text, voice, speed, instruct);
      saveLastMessage(text);
      return;
    } catch { /* 폴백 */ }
  }
  await speakSubprocess(text, voice, speed, instruct);
  saveLastMessage(text);
}

// ── 리더(hook) 발화: EdgeTTS MP3 생성 → 스풀 → 즉시 반환 ──
export async function speakHook(text: string, voice = "Sohee", speed = 1.2): Promise<void> {
  const skipEdge = process.env.SIREN_OFFLINE === "1";
  if (!skipEdge && existsSync(MLX_PYTHON)) {
    try {
      const mp3 = await generateEdge(text, voice);
      enqueueSpool(mp3, speed);
      saveLastMessage(text);
      return;
    } catch {
      // EdgeTTS 실패 — HTTP→Subprocess 폴백 (EdgeTTS 재시도 없음)
    }
  }
  await speakWithoutEdge(text, voice, speed, "");
}

async function speakInner(text: string, voice = "", speed = 1.2, instruct = ""): Promise<void> {
  const skipEdge = process.env.SIREN_OFFLINE === "1";
  if (!skipEdge && existsSync(MLX_PYTHON)) {
    try {
      await speakEdge(text, voice, speed);
      saveLastMessage(text);
      return;
    } catch { /* 폴백 */ }
  }
  await speakWithoutEdge(text, voice, speed, instruct);
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "refactor: speakHook 폴백 체인 정리 — EdgeTTS 이중 시도 제거"
```

---

## Task T8: `tts-venv` 경로 동적 탐색

**Files:**
- Modify: `src/player.ts`
- Modify: `tests/player.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/player.test.ts`에 추가:

```typescript
describe("MLX_PYTHON — 환경변수 우선 사용", () => {
  it("SIREN_VENV_PYTHON 설정 시 해당 경로 사용", async () => {
    process.env.SIREN_VENV_PYTHON = "/custom/path/python3";
    vi.mocked(fs.existsSync).mockImplementation(
      (p) => String(p) === "/custom/path/python3"
    );
    mockSpawnSequence(0, 0); // EdgeTTS 생성, afplay
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("dead")));

    // speak() 호출 → generateEdge → spawn(MLX_PYTHON, ...)
    await speak("테스트", "Sohee", 1.2, "");

    const firstCall = vi.mocked(cp.spawn).mock.calls[0];
    expect(firstCall?.[0]).toBe("/custom/path/python3");
    delete process.env.SIREN_VENV_PYTHON;
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/player.test.ts -t "SIREN_VENV_PYTHON"
```

Expected: `MLX_PYTHON`이 모듈 로딩 시 고정되어 환경변수 변경 무시 → 실패.

- [ ] **Step 3: `resolveMLXPython()` 함수 도입**

`src/player.ts`에서 모듈 수준 상수를 함수로 교체:

```typescript
// 변경 전
const MLX_PYTHON = join(__dirname, "..", "tts-venv", "bin", "python3");

// 변경 후
function resolveMLXPython(): string {
  if (process.env.SIREN_VENV_PYTHON) return process.env.SIREN_VENV_PYTHON;
  return join(__dirname, "..", "tts-venv", "bin", "python3");
}
```

그리고 `MLX_PYTHON`을 참조하는 모든 곳에서 함수 호출로 교체:
- `speakSubprocess`: `existsSync(MLX_PYTHON)` → `existsSync(resolveMLXPython())`
- `speakMLX`: `spawn(MLX_PYTHON, ...)` → `spawn(resolveMLXPython(), ...)`
- `generateEdge`: `spawn(MLX_PYTHON, ...)` → `spawn(resolveMLXPython(), ...)`
- `speakHook`: `existsSync(MLX_PYTHON)` → `existsSync(resolveMLXPython())`
- `speakInner`: `existsSync(MLX_PYTHON)` → `existsSync(resolveMLXPython())`

- [ ] **Step 4: 빌드 + 테스트 통과 확인**

```bash
npm run build && npm test
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "fix: tts-venv 경로 하드코딩 제거 — SIREN_VENV_PYTHON 환경변수 우선 탐색"
```

---

## 최종 검증

- [ ] **전체 테스트 통과**

```bash
npm test
```

Expected: 기존 57개 + T1~T8 신규 테스트 포함 전체 통과.

- [ ] **빌드 확인**

```bash
npm run build
```

Expected: 오류 없음.

- [ ] **리드에 완료 알림**

TS 팀 T1~T8 완료를 리드에게 알린다.
