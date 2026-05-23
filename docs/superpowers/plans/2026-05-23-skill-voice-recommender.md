# 스킬 음성 추천 기능 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code transcript를 LLM으로 분석해 현재 상황에 맞는 스킬 1개를 음성으로 추천하는 기능을 추가한다.

**Architecture:** SessionStart/UserPromptSubmit hook에서 HMG LLM API를 호출해 스킬을 추천하고, 기존 `speak()` 파이프라인으로 음성 안내한다. 쿨다운 상태는 파일로 공유하고, `suggest_skill`/`speak_last` MCP tool로 수동 호출도 지원한다.

**Tech Stack:** TypeScript, Node.js, `openai` SDK (HMG 내부 엔드포인트), vitest, bash

---

## 파일 구조

| 경로 | 역할 |
|------|------|
| `skills-catalog.json` | 신규 — LLM에 전달할 스킬명 + 설명 목록 |
| `src/last-message-store.ts` | 신규 — 마지막 TTS 텍스트 저장/읽기 |
| `src/skill-recommender.ts` | 신규 — transcript 읽기, LLM 호출, 쿨다운 관리 |
| `hooks/session-start.sh` | 신규 — SessionStart hook 스크립트 |
| `hooks/prompt-submit.sh` | 신규 — UserPromptSubmit hook 스크립트 |
| `src/config.ts` | 변경 — `skillCooldownMinutes` 필드 추가 |
| `src/player.ts` | 변경 — `speak()` 호출 시 last-message 저장 |
| `src/index.ts` | 변경 — `suggest_skill`, `speak_last` tool + hook CLI 분기 |
| `tests/last-message-store.test.ts` | 신규 — 저장/읽기 단위 테스트 |
| `tests/skill-recommender.test.ts` | 신규 — 파싱/쿨다운/catalog 매칭 단위 테스트 |

상태 저장 경로: `~/.local/share/summary-voice-mcp/` (hook 간 공유)

---

## Task 1: `skills-catalog.json` 작성

**Files:**
- Create: `skills-catalog.json`

- [ ] **Step 1: 파일 생성**

```json
[
  { "skill": "plan", "description": "다단계 작업 전 계획과 체크리스트를 먼저 작성" },
  { "skill": "code-review", "description": "변경된 코드의 버그·보안·품질 리뷰" },
  { "skill": "gitnexus-debugging", "description": "버그 원인 추적 및 에러 경로 분석" },
  { "skill": "gitnexus-exploring", "description": "코드베이스 아키텍처 이해 및 실행 흐름 탐색" },
  { "skill": "gitnexus-impact-analysis", "description": "변경 시 영향받는 코드 사전 분석" },
  { "skill": "gitnexus-refactoring", "description": "함수·파일·모듈 이름 변경 및 구조 개선" },
  { "skill": "k8s-debug", "description": "K8s 파드·서비스 로그 및 상태 디버깅" },
  { "skill": "pipeline", "description": "Kafka·Iceberg·Spark 데이터 파이프라인 진단" },
  { "skill": "docker-build", "description": "HMG 사내망 Docker 이미지 빌드 및 인증서 주입" },
  { "skill": "prp-pr", "description": "현재 브랜치의 변경사항으로 GitHub PR 자동 생성" },
  { "skill": "save-session", "description": "현재 세션 상태 저장 (장기 작업 이어받기)" },
  { "skill": "resume-session", "description": "이전 세션 컨텍스트 복원" },
  { "skill": "knowhow", "description": "PKM 자동화 — RSS 수집, RAG 인덱싱, 하이라이트 생성" },
  { "skill": "security-scan", "description": "훅·MCP·권한·시크릿 보안 취약점 스캔" },
  { "skill": "prp-prd", "description": "인터랙티브 PRD(제품 요구사항 문서) 생성" }
]
```

- [ ] **Step 2: 커밋**

```bash
cd ~/Develop/Workspaces/summary-voice-mcp
git add skills-catalog.json
git commit -m "feat: 스킬 카탈로그 JSON 추가"
```

---

## Task 2: `src/config.ts` — `skillCooldownMinutes` 추가

**Files:**
- Modify: `src/config.ts`
- Test: `tests/config.test.ts` (기존 파일)

- [ ] **Step 1: 기존 테스트에 필드 검증 추가**

`tests/config.test.ts` 의 `describe("loadConfig", ...)` 블록 끝에 추가:

```typescript
  it("skillCooldownMinutes 기본값 30", () => {
    const c = loadConfig("/nonexistent/path.json");
    expect(c.skillCooldownMinutes).toBe(30);
  });
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test -- tests/config.test.ts
```

Expected: FAIL — `Property 'skillCooldownMinutes' does not exist`

- [ ] **Step 3: `SirenConfig` 인터페이스 및 기본값 수정**

`src/config.ts`:

```typescript
// 사용자 설정 파일 로더 및 기본값 관리
import { readFileSync, existsSync } from "fs";

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
}

const DEFAULTS: SirenConfig = {
  autoSpeak: true,
  minChars: 200,
  voice: "Sohee",
  summaryModel: "gpt-5.4",
  ttsModel: "tts-1",
  language: "ko",
  ttsSpeed: 1.2,
  ttsInstruct: "밝고 활기차게 말해주세요",
  skillCooldownMinutes: 30,
};

export function loadConfig(path?: string): SirenConfig {
  const target = path ?? new URL(".siren.json", import.meta.url).pathname;
  if (!existsSync(target)) return { ...DEFAULTS };
  try {
    return { ...DEFAULTS, ...JSON.parse(readFileSync(target, "utf-8")) };
  } catch {
    return { ...DEFAULTS };
  }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test -- tests/config.test.ts
```

Expected: PASS (기존 3개 + 신규 1개)

- [ ] **Step 5: 커밋**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat(config): skillCooldownMinutes 필드 추가 (기본값 30분)"
```

---

## Task 3: `src/last-message-store.ts` 생성

**Files:**
- Create: `src/last-message-store.ts`
- Create: `tests/last-message-store.test.ts`

- [ ] **Step 1: 테스트 파일 작성**

`tests/last-message-store.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const DATA_DIR = join(homedir(), ".local", "share", "summary-voice-mcp-test");
process.env.SIREN_DATA_DIR = DATA_DIR;

import { saveLastMessage, loadLastMessage } from "../src/last-message-store.js";

beforeEach(() => {
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
});

afterEach(() => {
  if (existsSync(DATA_DIR)) rmSync(DATA_DIR, { recursive: true });
});

describe("last-message-store", () => {
  it("저장 후 읽으면 동일 텍스트 반환", () => {
    saveLastMessage("안녕하세요");
    expect(loadLastMessage()).toBe("안녕하세요");
  });

  it("저장 전 읽으면 null 반환", () => {
    expect(loadLastMessage()).toBeNull();
  });

  it("빈 문자열도 저장/읽기 정상 동작", () => {
    saveLastMessage("");
    expect(loadLastMessage()).toBe("");
  });
});
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test -- tests/last-message-store.test.ts
```

Expected: FAIL — `Cannot find module '../src/last-message-store.js'`

- [ ] **Step 3: 구현 파일 작성**

`src/last-message-store.ts`:

```typescript
// 마지막 TTS 재생 텍스트 저장 및 읽기 — /replay 기능 지원
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";

function getDataDir(): string {
  return process.env.SIREN_DATA_DIR ?? join(homedir(), ".local", "share", "summary-voice-mcp");
}

function getLastMsgFile(): string {
  return join(getDataDir(), "last-message.txt");
}

function ensureDir(): void {
  const dir = getDataDir();
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

export function saveLastMessage(text: string): void {
  try {
    ensureDir();
    writeFileSync(getLastMsgFile(), text, "utf-8");
  } catch { /* silent fail */ }
}

export function loadLastMessage(): string | null {
  try {
    const file = getLastMsgFile();
    if (!existsSync(file)) return null;
    return readFileSync(file, "utf-8");
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test -- tests/last-message-store.test.ts
```

Expected: PASS (3개)

- [ ] **Step 5: 커밋**

```bash
git add src/last-message-store.ts tests/last-message-store.test.ts
git commit -m "feat: last-message-store 추가 — /replay 지원용 TTS 텍스트 저장"
```

---

## Task 4: `src/player.ts` — `speak()` 호출 시 저장

**Files:**
- Modify: `src/player.ts`
- Test: `tests/player.test.ts` (기존 파일에 검증 추가)

- [ ] **Step 1: 기존 player.test.ts에 저장 검증 추가**

`tests/player.test.ts` 상단 import 블록 뒤에 추가:

```typescript
vi.mock("../src/last-message-store.js", () => ({
  saveLastMessage: vi.fn(),
}));
import * as store from "../src/last-message-store.js";
```

그리고 기존 describe 블록 안에 테스트 추가:

```typescript
  it("speak 성공 시 saveLastMessage 호출", async () => {
    const proc = makeOnceProc(0);
    vi.mocked(cp.spawn).mockReturnValue(proc);
    await speak("테스트", "Sohee", 1.0, "");
    expect(vi.mocked(store.saveLastMessage)).toHaveBeenCalledWith("테스트");
  });
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test -- tests/player.test.ts
```

Expected: FAIL — `saveLastMessage` 호출 없음

- [ ] **Step 3: `player.ts` 수정 — `speak()` 끝에 저장 추가**

`src/player.ts` 의 `speak()` 함수를 아래로 교체:

```typescript
export async function speak(text: string, voice = "", speed = 1.2, instruct = ""): Promise<void> {
  // 1. EdgeTTS (온라인 우선, tts-venv에 edge-tts 설치 필요)
  if (existsSync(MLX_PYTHON)) {
    try {
      await speakEdge(text, voice, speed);
      saveLastMessage(text);
      return;
    } catch {
      // 네트워크 오류 또는 타임아웃 시 폴백
    }
  }
  // 2. HTTP TTS 서버 (MLX 상주 서버가 기동 중인 경우)
  if (await isTTSServerAlive()) {
    try {
      await speakHTTP(text, voice, speed, instruct);
      saveLastMessage(text);
      return;
    } catch {
      // 서버 응답 실패 시 폴백
    }
  }
  // 3. MLX subprocess → 4. macOS say
  await speakSubprocess(text, voice, speed, instruct);
  saveLastMessage(text);
}
```

그리고 `player.ts` 상단 import에 추가:

```typescript
import { saveLastMessage } from "./last-message-store.js";
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test -- tests/player.test.ts
```

Expected: 기존 테스트 포함 모두 PASS

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "feat(player): speak() 호출 시 last-message 자동 저장"
```

---

## Task 5: `src/skill-recommender.ts` 생성

**Files:**
- Create: `src/skill-recommender.ts`
- Create: `tests/skill-recommender.test.ts`

- [ ] **Step 1: 테스트 파일 작성**

`tests/skill-recommender.test.ts`:

```typescript
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
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test -- tests/skill-recommender.test.ts
```

Expected: FAIL — `Cannot find module '../src/skill-recommender.js'`

- [ ] **Step 3: 구현 파일 작성**

`src/skill-recommender.ts`:

```typescript
// 사용자 transcript 분석 → HMG LLM → 스킬 추천 + 쿨다운 관리
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from "fs";
import { homedir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import OpenAI from "openai";

const __dirname = dirname(fileURLToPath(import.meta.url));

const HUB_BASE_URL = process.env.HUB_BASE_URL ?? "https://internal-apigw-kr.hmg-corp.io/hchat-in/api/v3";
const HUB_API_KEY  = process.env.HUB_API_KEY  ?? "";
const HUB_PROJECT_ID = process.env.HUB_PROJECT_ID ?? "";
const CATALOG_FILE = join(__dirname, "..", "skills-catalog.json");

function getDataDir(): string {
  return process.env.SIREN_DATA_DIR ?? join(homedir(), ".local", "share", "summary-voice-mcp");
}

function getCooldownsFile(): string {
  return join(getDataDir(), "skill-cooldowns.json");
}

export interface SkillEntry {
  skill: string;
  description: string;
}

export interface Recommendation {
  skill: string;
  reason: string;
}

export function parseCatalog(raw: string): SkillEntry[] {
  try {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return [];
    return arr;
  } catch {
    return [];
  }
}

export function parseRecommendation(raw: string, catalog: SkillEntry[]): Recommendation | null {
  try {
    const rec = JSON.parse(raw);
    if (!rec?.skill) return null;
    if (!catalog.some((s) => s.skill === rec.skill)) return null;
    return { skill: rec.skill, reason: rec.reason ?? "" };
  } catch {
    return null;
  }
}

export function loadCatalog(): SkillEntry[] {
  try {
    return parseCatalog(readFileSync(CATALOG_FILE, "utf-8"));
  } catch {
    return [];
  }
}

export function readRecentTranscripts(
  transcriptsDir = join(homedir(), ".claude", "transcripts"),
  maxFiles = 3,
  maxLinesPerFile = 50
): string {
  try {
    if (!existsSync(transcriptsDir)) return "";
    const files = readdirSync(transcriptsDir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({ name: f, mtime: statSync(join(transcriptsDir, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, maxFiles)
      .map((f) => f.name);

    return files
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
  } catch {
    return "";
  }
}

export function loadCooldowns(): Record<string, string> {
  try {
    if (!existsSync(getCooldownsFile())) return {};
    return JSON.parse(readFileSync(getCooldownsFile(), "utf-8"));
  } catch {
    return {};
  }
}

export function saveCooldown(skill: string): void {
  try {
    const dir = getDataDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const cooldowns = loadCooldowns();
    cooldowns[skill] = new Date().toISOString();
    writeFileSync(getCooldownsFile(), JSON.stringify(cooldowns, null, 2), "utf-8");
  } catch { /* silent fail */ }
}

export function isInCooldown(
  skill: string,
  cooldowns: Record<string, string>,
  cooldownMinutes: number
): boolean {
  const last = cooldowns[skill];
  if (!last) return false;
  const elapsedMin = (Date.now() - new Date(last).getTime()) / 60000;
  return elapsedMin < cooldownMinutes;
}

export async function recommendSkill(
  context: string,
  bypassCooldown = false,
  cooldownMinutes = 30
): Promise<Recommendation | null> {
  const catalog = loadCatalog();
  if (catalog.length === 0 || !context.trim()) return null;

  const skillsText = catalog.map((s) => `- ${s.skill}: ${s.description}`).join("\n");
  const prompt =
    `다음은 Claude Code 대화 히스토리 일부입니다:\n<transcript>\n${context}\n</transcript>\n\n` +
    `다음은 사용 가능한 스킬 목록입니다:\n<skills>\n${skillsText}\n</skills>\n\n` +
    `위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.\n` +
    `반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.\n` +
    `{"skill": "<스킬명>", "reason": "<한 문장 이유>"}`;

  try {
    const extraHeaders: Record<string, string> = {};
    if (HUB_PROJECT_ID) extraHeaders["X-Project-Id"] = HUB_PROJECT_ID;
    const client = new OpenAI({
      apiKey: HUB_API_KEY,
      baseURL: `${HUB_BASE_URL}/openai/deployments/gpt-5.4`,
      defaultHeaders: extraHeaders,
    });

    const resp = await client.chat.completions.create({
      model: "gpt-5.4",
      messages: [{ role: "user", content: prompt }],
      max_completion_tokens: 100,
      temperature: 0.2,
    });

    const raw = resp.choices[0]?.message?.content?.trim() ?? "";
    const rec = parseRecommendation(raw, catalog);
    if (!rec) return null;

    if (!bypassCooldown && isInCooldown(rec.skill, loadCooldowns(), cooldownMinutes)) return null;

    return rec;
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test -- tests/skill-recommender.test.ts
```

Expected: PASS (8개)

- [ ] **Step 5: 커밋**

```bash
git add src/skill-recommender.ts tests/skill-recommender.test.ts
git commit -m "feat: skill-recommender — transcript 분석 및 LLM 스킬 추천"
```

---

## Task 6: `src/index.ts` — MCP tool 및 hook CLI 분기 추가

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: `ListToolsRequestSchema` 핸들러에 tool 2개 추가**

기존 `tools: [...]` 배열 끝에 추가:

```typescript
    {
      name: "suggest_skill",
      description: "현재 transcript를 분석해 유용한 스킬 1개를 음성으로 추천합니다. 쿨다운을 무시하고 강제 추천합니다.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "speak_last",
      description: "마지막으로 재생한 TTS 텍스트를 다시 읽어줍니다.",
      inputSchema: { type: "object" as const, properties: {} },
    },
```

- [ ] **Step 2: `CallToolRequestSchema` 핸들러에 분기 추가**

기존 `if (name === "set_config")` 블록 아래에 추가:

```typescript
    if (name === "suggest_skill") {
      const context = readRecentTranscripts();
      const rec = await recommendSkill(context, true, config.skillCooldownMinutes);
      if (rec) {
        const msg = `지금 상황엔 ${rec.skill} 스킬이 유용할 것 같아요`;
        await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
        saveCooldown(rec.skill);
        return { content: [{ type: "text" as const, text: `추천: ${rec.skill}` }] };
      }
      return { content: [{ type: "text" as const, text: "추천할 스킬을 찾지 못했습니다" }] };
    }
    if (name === "speak_last") {
      const last = loadLastMessage();
      if (!last) {
        const msg = "재생할 내용이 없어요";
        await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
        return { content: [{ type: "text" as const, text: msg }] };
      }
      await speak(last, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
      return { content: [{ type: "text" as const, text: "재생 완료" }] };
    }
```

- [ ] **Step 3: hook CLI 분기 추가**

기존 `if (process.argv[2] === "hook")` 블록 아래에 추가:

```typescript
if (process.argv[2] === "hook-suggest") {
  const context = process.argv[3] ?? readRecentTranscripts();
  const rec = await recommendSkill(context, false, config.skillCooldownMinutes);
  if (rec) {
    const msg = `지금 상황엔 ${rec.skill} 스킬이 유용할 것 같아요`;
    await speak(msg, config.voice, config.ttsSpeed, config.ttsInstruct).catch(() => {});
    saveCooldown(rec.skill);
  }
  process.exit(0);
}
```

- [ ] **Step 4: 상단 import 추가**

`src/index.ts` 상단에 추가:

```typescript
import { recommendSkill, readRecentTranscripts, saveCooldown } from "./skill-recommender.js";
import { loadLastMessage } from "./last-message-store.js";
```

- [ ] **Step 5: 빌드 확인**

```bash
npm run build
```

Expected: 에러 없이 `dist/` 생성

- [ ] **Step 6: 커밋**

```bash
git add src/index.ts
git commit -m "feat(index): suggest_skill·speak_last MCP tool 및 hook-suggest CLI 분기 추가"
```

---

## Task 7: `hooks/session-start.sh` 생성

**Files:**
- Create: `hooks/session-start.sh`

SessionStart hook은 Claude Code가 세션 시작 시 stdin으로 JSON을 전달한다. 스킬 추천은 비동기로 실행해 hook timeout에 영향을 주지 않는다.

- [ ] **Step 1: 스크립트 생성**

`hooks/session-start.sh`:

```bash
#!/usr/bin/env bash
# Claude Code SessionStart hook — 세션 시작 시 스킬 추천

# stdin 데이터 읽기 (사용하지 않지만 drain 필요)
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 비동기 실행 — hook timeout과 무관하게 TTS 완료까지 재생
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest > /dev/null 2>&1 &
disown $!

exit 0
```

- [ ] **Step 2: 실행 권한 부여**

```bash
chmod +x ~/Develop/Workspaces/summary-voice-mcp/hooks/session-start.sh
```

- [ ] **Step 3: 커밋**

```bash
git add hooks/session-start.sh
git commit -m "feat(hooks): SessionStart hook — 세션 시작 시 스킬 추천 트리거"
```

---

## Task 8: `hooks/prompt-submit.sh` 생성

**Files:**
- Create: `hooks/prompt-submit.sh`

UserPromptSubmit hook은 stdin으로 `{"prompt": "...", "session_id": "..."}` JSON을 전달한다.

- [ ] **Step 1: 스크립트 생성**

`hooks/prompt-submit.sh`:

```bash
#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천

HOOK_DATA=$(cat)

PROMPT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# 프롬프트가 너무 짧으면 스킵 (인사말 등)
if [ "${#PROMPT}" -lt 10 ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 비동기 실행 — hook timeout과 무관하게 TTS 완료까지 재생
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest "$PROMPT" > /dev/null 2>&1 &
disown $!

exit 0
```

- [ ] **Step 2: 실행 권한 부여**

```bash
chmod +x ~/Develop/Workspaces/summary-voice-mcp/hooks/prompt-submit.sh
```

- [ ] **Step 3: 커밋**

```bash
git add hooks/prompt-submit.sh
git commit -m "feat(hooks): UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천 트리거"
```

---

## Task 9: Claude Code settings.json hook 등록

**Files:**
- Modify: `~/.claude/settings.json`

현재 `Stop` hook만 등록되어 있다. `SessionStart`와 `UserPromptSubmit` hook을 전역 설정에 추가한다.

- [ ] **Step 1: `~/.claude/settings.json` 의 `hooks` 객체에 추가**

기존 `"Stop": [...]` 배열 옆에 아래 두 섹션을 추가한다:

```json
"SessionStart": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "/Users/hmc7102758/Develop/Workspaces/summary-voice-mcp/hooks/session-start.sh",
        "timeout": 5
      }
    ]
  }
],
"UserPromptSubmit": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "/Users/hmc7102758/Develop/Workspaces/summary-voice-mcp/hooks/prompt-submit.sh",
        "timeout": 5
      }
    ]
  }
]
```

- [ ] **Step 2: 빌드 및 smoke test**

```bash
cd ~/Develop/Workspaces/summary-voice-mcp
npm run build
node dist/index.js hook-suggest "버그를 디버깅하고 싶습니다"
```

Expected: `gitnexus-debugging` 또는 관련 스킬 음성 재생 (API 호출 성공 시)

- [ ] **Step 3: 전체 테스트 통과 확인**

```bash
npm test
```

Expected: 모든 테스트 PASS

- [ ] **Step 4: 커밋**

```bash
cd ~/Develop/Workspaces/summary-voice-mcp
git add -A
git commit -m "feat: 스킬 음성 추천 기능 완성 — SessionStart·UserPromptSubmit hook 등록"
```

---

## 검증 체크리스트

- [ ] `npm test` 전체 통과
- [ ] `npm run build` 에러 없음
- [ ] `node dist/index.js hook-suggest "K8s 파드 로그 확인"` → 음성 재생
- [ ] `node dist/index.js hook-suggest "K8s 파드 로그 확인"` 30분 내 재실행 → 무음 (쿨다운)
- [ ] Claude Code에서 `/suggest_skill` MCP tool 호출 → 음성 재생
- [ ] Claude Code에서 `/speak_last` MCP tool 호출 → 직전 TTS 재생
- [ ] 새 Claude Code 세션 시작 → 세션 시작 스킬 추천 재생
