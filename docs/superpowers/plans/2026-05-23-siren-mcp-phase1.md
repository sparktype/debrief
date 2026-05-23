# siren-mcp Phase 1 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code Stop hook + MCP tool 두 경로로 답변 텍스트를 macOS `say`로 음성 재생하는 MCP 서버 Phase 1 구현

**Architecture:** TypeScript MCP 서버(`@modelcontextprotocol/sdk`)가 `speak_text` / `summarize_and_speak` / `set_config` 세 tool을 제공한다. `index.ts`는 `hook` 서브커맨드 분기로 stdio MCP 모드와 CLI hook 모드를 함께 처리한다. 요약은 규칙 기반(마지막 N문장 추출)으로 Phase 1을 완성하고, Phase 2에서 GPT + OpenAI TTS로 교체한다.

**Tech Stack:** Node.js 20+, TypeScript 5, `@modelcontextprotocol/sdk ^1.10`, `tsx` (dev), `vitest` (test)

---

## 파일 맵

| 경로 | 역할 |
|------|------|
| `package.json` | 의존성, bin, scripts |
| `tsconfig.json` | TypeScript 설정 |
| `.gitignore` | dist, node_modules 제외 |
| `src/config.ts` | `.siren.json` 로드 + 기본값 |
| `src/summarizer.ts` | 마지막 N문장 추출 (Phase 1 규칙 기반) |
| `src/player.ts` | macOS `say` 명령으로 재생 |
| `src/index.ts` | MCP 서버 진입점 + `hook` CLI 분기 |
| `tests/config.test.ts` | config 단위 테스트 |
| `tests/summarizer.test.ts` | summarizer 단위 테스트 |
| `tests/player.test.ts` | player 단위 테스트 |
| `hooks/stop.sh` | Claude Code Stop hook 스크립트 |

---

## Task 1: 프로젝트 초기화

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `.gitignore`

- [ ] **Step 1: package.json 생성**

```json
{
  "name": "siren-mcp",
  "version": "0.1.0",
  "description": "Claude Code 답변을 음성으로 전달하는 MCP 서버",
  "type": "module",
  "bin": {
    "siren-mcp": "./dist/index.js"
  },
  "scripts": {
    "build": "tsc",
    "dev": "tsx src/index.ts",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.10.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.0.0",
    "vitest": "^2.0.0"
  }
}
```

- [ ] **Step 2: tsconfig.json 생성**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

- [ ] **Step 3: .gitignore 생성**

```
node_modules/
dist/
*.mp3
.siren.json
```

- [ ] **Step 4: 의존성 설치**

```bash
npm install
```

Expected: `node_modules/` 생성, 오류 없음.

- [ ] **Step 5: 커밋**

```bash
git add package.json tsconfig.json .gitignore package-lock.json
git commit -m "chore: 프로젝트 초기화"
```

---

## Task 2: config 로더

**Files:**
- Create: `src/config.ts`
- Create: `tests/config.test.ts`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/config.test.ts`:
```typescript
import { describe, it, expect, afterEach } from "vitest";
import { writeFileSync, unlinkSync, existsSync } from "fs";
import { loadConfig } from "../src/config.js";

const TMP = "/tmp/test-siren.json";

afterEach(() => { if (existsSync(TMP)) unlinkSync(TMP); });

describe("loadConfig", () => {
  it("파일 없으면 기본값 반환", () => {
    const c = loadConfig("/nonexistent/path.json");
    expect(c.autoSpeak).toBe(true);
    expect(c.minChars).toBe(500);
    expect(c.voice).toBe("nova");
    expect(c.language).toBe("ko");
  });

  it("파일 있으면 기본값에 병합", () => {
    writeFileSync(TMP, JSON.stringify({ minChars: 300, voice: "alloy" }));
    const c = loadConfig(TMP);
    expect(c.minChars).toBe(300);
    expect(c.voice).toBe("alloy");
    expect(c.autoSpeak).toBe(true); // 기본값 유지
  });

  it("JSON 파싱 실패 시 기본값 반환", () => {
    writeFileSync(TMP, "not json");
    const c = loadConfig(TMP);
    expect(c.minChars).toBe(500);
  });
});
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test
```

Expected: FAIL — `Cannot find module '../src/config.js'`

- [ ] **Step 3: src/config.ts 구현**

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
}

const DEFAULTS: SirenConfig = {
  autoSpeak: true,
  minChars: 500,
  voice: "nova",
  summaryModel: "gpt-4o-mini",
  ttsModel: "tts-1",
  language: "ko",
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
npm test
```

Expected: PASS — 3 tests

- [ ] **Step 5: 커밋**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat: config 로더 구현"
```

---

## Task 3: summarizer (규칙 기반)

**Files:**
- Create: `src/summarizer.ts`
- Create: `tests/summarizer.test.ts`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/summarizer.test.ts`:
```typescript
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
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test
```

Expected: FAIL — `Cannot find module '../src/summarizer.js'`

- [ ] **Step 3: src/summarizer.ts 구현**

```typescript
// 텍스트에서 핵심 문장 추출 (Phase 1: 규칙 기반)

export function extractSummary(text: string, sentenceCount = 3): string {
  if (!text.trim()) return "";

  const cleaned = text
    .replace(/```[\s\S]*?```/g, "")   // 코드 블록 제거
    .replace(/`[^`]+`/g, "")          // 인라인 코드 제거
    .replace(/#{1,6} .+/gm, "")       // 마크다운 헤더 제거
    .replace(/\n+/g, " ")
    .trim();

  const sentences = cleaned
    .split(/(?<=[.!?。])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 5);

  if (sentences.length === 0) return cleaned;
  return sentences.slice(-sentenceCount).join(" ");
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test
```

Expected: PASS — 4 tests

- [ ] **Step 5: 커밋**

```bash
git add src/summarizer.ts tests/summarizer.test.ts
git commit -m "feat: 규칙 기반 요약 추출 구현"
```

---

## Task 4: player (say 명령)

**Files:**
- Create: `src/player.ts`
- Create: `tests/player.test.ts`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/player.test.ts`:
```typescript
import { describe, it, expect, vi, afterEach } from "vitest";
import * as cp from "child_process";
import { EventEmitter } from "events";

// player.ts를 import하기 전에 spy 설정
vi.mock("child_process", async (importOriginal) => {
  const orig = await importOriginal<typeof cp>();
  return { ...orig, spawn: vi.fn() };
});

import { speak } from "../src/player.js";

afterEach(() => vi.clearAllMocks());

function mockProc(exitCode: number) {
  const proc = new EventEmitter() as any;
  proc.stderr = new EventEmitter();
  vi.mocked(cp.spawn).mockReturnValue(proc as any);
  setImmediate(() => proc.emit("close", exitCode));
  return proc;
}

describe("speak", () => {
  it("say 성공 시 resolve", async () => {
    mockProc(0);
    await expect(speak("안녕")).resolves.toBeUndefined();
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });

  it("say 실패 시 reject", async () => {
    mockProc(1);
    await expect(speak("안녕")).rejects.toThrow("say 명령 실패");
  });

  it("spawn 오류 시 reject", async () => {
    const proc = new EventEmitter() as any;
    proc.stderr = new EventEmitter();
    vi.mocked(cp.spawn).mockReturnValue(proc as any);
    setImmediate(() => proc.emit("error", new Error("ENOENT")));
    await expect(speak("안녕")).rejects.toThrow("ENOENT");
  });
});
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npm test
```

Expected: FAIL — `Cannot find module '../src/player.js'`

- [ ] **Step 3: src/player.ts 구현**

```typescript
// macOS say 명령으로 텍스트를 음성 재생
import { spawn } from "child_process";

export function speak(text: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("say", [text]);
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`say 명령 실패: exit ${code}`));
    });
    proc.on("error", reject);
  });
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npm test
```

Expected: PASS — 3 tests

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "feat: say 명령 플레이어 구현"
```

---

## Task 5: MCP 서버 + hook CLI

**Files:**
- Create: `src/index.ts`

> 이 파일은 두 모드로 동작한다.
> - `node dist/index.js` → stdio MCP 서버 모드
> - `node dist/index.js hook <text>` → CLI hook 모드 (TTS만 실행 후 종료)

- [ ] **Step 1: src/index.ts 작성**

```typescript
// MCP 서버 진입점 — tool 등록 및 hook CLI 분기
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { loadConfig, SirenConfig } from "./config.js";
import { extractSummary } from "./summarizer.js";
import { speak } from "./player.js";

let config: SirenConfig = loadConfig();

// ── hook CLI 모드 ──────────────────────────────────────────
// 사용 예: node dist/index.js hook "읽을 텍스트"
if (process.argv[2] === "hook") {
  const text = process.argv.slice(3).join(" ");
  if (text.length >= config.minChars) {
    const summary = extractSummary(text);
    await speak(summary).catch(() => {}); // silent fail
  }
  process.exit(0);
}

// ── MCP 서버 모드 ──────────────────────────────────────────
const server = new Server(
  { name: "siren-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "speak_text",
      description: "전달한 텍스트를 그대로 음성으로 재생합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          text: { type: "string", description: "읽을 텍스트" },
        },
        required: ["text"],
      },
    },
    {
      name: "summarize_and_speak",
      description: "텍스트에서 핵심 문장을 추출해 음성으로 재생합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          text: { type: "string", description: "요약할 텍스트" },
        },
        required: ["text"],
      },
    },
    {
      name: "set_config",
      description: "siren-mcp 설정을 런타임에 변경합니다.",
      inputSchema: {
        type: "object" as const,
        properties: {
          autoSpeak: { type: "boolean" },
          minChars: { type: "number" },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  try {
    if (name === "speak_text") {
      await speak(String(args?.text ?? ""));
      return { content: [{ type: "text" as const, text: "재생 완료" }] };
    }
    if (name === "summarize_and_speak") {
      const text = String(args?.text ?? "");
      const summary = extractSummary(text);
      await speak(summary);
      return { content: [{ type: "text" as const, text: `요약 재생: ${summary}` }] };
    }
    if (name === "set_config") {
      config = { ...config, ...(args as Partial<SirenConfig>) };
      return { content: [{ type: "text" as const, text: "설정 변경 완료" }] };
    }
    throw new Error(`알 수 없는 tool: ${name}`);
  } catch (err) {
    // TTS 실패는 silent fail
    const msg = err instanceof Error ? err.message : String(err);
    return { content: [{ type: "text" as const, text: `오류 (무시됨): ${msg}` }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
```

- [ ] **Step 2: 빌드 확인**

```bash
npm run build
```

Expected: `dist/index.js` 생성, 오류 없음.

- [ ] **Step 3: 수동 smoke test — speak_text**

```bash
node dist/index.js hook "안녕하세요 테스트입니다."
```

Expected: macOS가 텍스트를 음성으로 읽음. (텍스트가 500자 미만이면 스킵 — 500자 이상 텍스트로 테스트)

길이 제한 없이 테스트:
```bash
# config minChars를 0으로 임시 설정
SIREN_MIN_CHARS=0 node -e "
process.argv = ['node', 'dist/index.js', 'hook', '안녕하세요 테스트입니다'];
import('./dist/index.js');
"
```

또는 `.siren.json`을 임시 생성:
```bash
echo '{"minChars": 0}' > .siren.json
node dist/index.js hook "안녕하세요 테스트입니다"
rm .siren.json
```

Expected: 음성 재생됨.

- [ ] **Step 4: 커밋**

```bash
git add src/index.ts dist/
git commit -m "feat: MCP 서버 및 hook CLI 구현"
```

---

## Task 6: Stop hook 연결

**Files:**
- Create: `hooks/stop.sh`

- [ ] **Step 1: hooks/stop.sh 작성**

```bash
#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행

# stdin에서 hook 데이터 읽기
HOOK_DATA=$(cat)

# transcript에서 마지막 assistant 메시지 추출
TEXT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    transcript = data.get('transcript', [])
    for msg in reversed(transcript):
        if msg.get('role') == 'assistant':
            content = msg.get('content', '')
            if isinstance(content, list):
                content = ' '.join(
                    c.get('text', '') for c in content if c.get('type') == 'text'
                )
            print(content, end='')
            break
except Exception:
    pass
" 2>/dev/null)

# 텍스트가 없으면 종료
if [ -z "\$TEXT" ]; then
  exit 0
fi

# siren-mcp hook 모드로 실행 (TTS 실패해도 0 exit)
node "\$(npm root -g)/siren-mcp/dist/index.js" hook "\$TEXT" 2>/dev/null || true
exit 0
```

- [ ] **Step 2: 실행 권한 부여**

```bash
chmod +x hooks/stop.sh
```

- [ ] **Step 3: Claude Code settings에 hook 등록**

`~/.claude/settings.json`을 열어 아래 내용 추가 (기존 hooks가 있으면 병합):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/hmc7102758/Develop/Workspaces/siren-mcp/hooks/stop.sh"
          }
        ]
      }
    ]
  }
}
```

> **주의**: 전역 설치 후에는 경로를 절대 경로 대신 `npx siren-mcp hook` 방식으로 변경 가능.

- [ ] **Step 4: hook 동작 확인**

Claude Code에서 긴 답변(500자 이상)이 나오는 질문을 해서 자동 재생 확인.

예: "HTTP와 HTTPS의 차이를 자세히 설명해줘"

Expected: 응답 완료 후 macOS가 마지막 3문장을 읽음.

- [ ] **Step 5: 커밋**

```bash
git add hooks/stop.sh
git commit -m "feat: Claude Code Stop hook 연결"
```

---

## Task 7: 최종 검증

- [ ] **Step 1: 전체 테스트 실행**

```bash
npm test
```

Expected: PASS — 모든 단위 테스트 통과.

- [ ] **Step 2: MCP Inspector로 tool 수동 검증**

```bash
npx @modelcontextprotocol/inspector node dist/index.js
```

Inspector에서:
1. `speak_text` 호출 → `{ "text": "테스트 메시지입니다" }` → 음성 재생 확인
2. `summarize_and_speak` 호출 → 500자 이상 텍스트 → 마지막 3문장 요약 재생 확인
3. `set_config` 호출 → `{ "autoSpeak": false }` → 설정 변경 확인

- [ ] **Step 3: Claude Code에 MCP 등록**

```bash
claude mcp add siren-mcp -- node /Users/hmc7102758/Develop/Workspaces/siren-mcp/dist/index.js
```

Expected: `claude mcp list`에 `siren-mcp` 표시.

- [ ] **Step 4: 최종 커밋**

```bash
git add -A
git commit -m "chore: Phase 1 구현 완료"
```

---

## 다음 단계 (Phase 2)

Phase 1 검증 완료 후:
1. `src/tts.ts` — OpenAI TTS API로 MP3 생성 및 `afplay` 재생
2. `src/summarizer.ts` 교체 — GPT-4o-mini API 호출로 한국어 요약
3. 오디오 큐 (`src/queue.ts`) — 연속 응답 겹침 방지
4. `OPENAI_API_KEY` 없으면 `say` 모드로 폴백
