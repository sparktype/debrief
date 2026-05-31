# Supertonic 에이전트 다성 TTS 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code 서브에이전트 타입별로 Supertonic 다성 TTS를 연결해 각 에이전트 카테고리(Reviewer/Planner/Builder/Explorer/Default)가 서로 다른 목소리로 발화한다.

**Architecture:** SubagentStop hook에서 transcript.jsonl을 파싱해 에이전트 타입을 감지하고, `voice-map.json` 설정으로 Supertonic voice를 선택해 포트 7788에 HTTP 요청한다. 기존 Stop hook(메인 Claude → EdgeTTS/MLX)과 독립적으로 공존한다.

**Tech Stack:** TypeScript/Node.js, `supertonic[serve]` PyPI, FastAPI(supertonic 내장), vitest, bash

---

## 파일 구조

| 파일 | 역할 |
|------|------|
| `voice-map.json` | 카테고리·에이전트·voice 매핑 설정 (신규) |
| `src/voice-router.ts` | agentType → category → voice 해석 로직 (신규) |
| `src/player.ts` | `speakSupertonic()`, `speakAgent()` 추가 (수정) |
| `src/config.ts` | `supertonicPort` 필드 추가 (수정) |
| `src/index.ts` | `subagent-stop` CLI 분기 추가 (수정) |
| `hooks/subagent-stop.sh` | SubagentStop hook 스크립트 (신규) |
| `tts_server/supertonic_start.sh` | Supertonic 서버 시작 스크립트 (신규) |
| `tts_server/supertonic_stop.sh` | Supertonic 서버 종료 스크립트 (신규) |
| `server.sh` | Supertonic 서버 관리 추가 (수정) |
| `setup-tts.sh` | supertonic[serve] 설치 추가 (수정) |
| `tests/voice-router.test.ts` | voice-router 단위 테스트 (신규) |

---

## Task 1: Supertonic 패키지 설치

**Files:**
- Modify: `setup-tts.sh`
- Create: `tts_server/supertonic_start.sh`
- Create: `tts_server/supertonic_stop.sh`

- [ ] **Step 1: setup-tts.sh에 supertonic[serve] 설치 블록 추가**

`setup-tts.sh`의 `edge-tts 설치` 블록(73~78번째 줄) 바로 아래에 다음을 삽입:

```bash
# ── 5. supertonic 설치 (Supertonic 온디바이스 TTS) ─────────────────────────
step "supertonic 설치"

if "${PYTHON}" -c "import supertonic" &>/dev/null 2>&1; then
  ok "supertonic이 이미 설치되어 있습니다 — 스킵"
else
  "${PIP}" install -q 'supertonic[serve]'
  ok "supertonic 설치 완료"
fi
```

> **주의**: 기존 5~8번 step 번호를 6~9로 변경.

- [ ] **Step 2: Supertonic 서버 시작 스크립트 생성**

`tts_server/supertonic_start.sh`를 생성:

```bash
#!/usr/bin/env bash
# Supertonic TTS 서버 시작 스크립트 (포트 7788)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BIN="$SCRIPT_DIR/../tts-venv/bin"
PID_FILE="$SCRIPT_DIR/../.supertonic.pid"
LOG_FILE="/tmp/supertonic.log"
PORT=7788

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[Supertonic] 이미 실행 중 (PID $(cat "$PID_FILE"))"
    exit 0
fi

if ! [ -f "$VENV_BIN/supertonic" ]; then
    echo "[Supertonic] supertonic 미설치. setup-tts.sh를 먼저 실행하세요." >&2
    exit 1
fi

nohup "$VENV_BIN/supertonic" serve --host 127.0.0.1 --port "$PORT" \
    > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "[Supertonic] 서버 시작 (PID $!, 포트 $PORT, 로그 $LOG_FILE)"
```

- [ ] **Step 3: Supertonic 서버 종료 스크립트 생성**

`tts_server/supertonic_stop.sh`를 생성:

```bash
#!/usr/bin/env bash
# Supertonic TTS 서버 종료 스크립트
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/../.supertonic.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    kill "$PID" 2>/dev/null && echo "[Supertonic] 서버 종료 (PID $PID)" || true
    rm -f "$PID_FILE"
else
    echo "[Supertonic] 실행 중인 서버 없음"
fi
```

- [ ] **Step 4: 실행 권한 부여**

```bash
chmod +x tts_server/supertonic_start.sh tts_server/supertonic_stop.sh
```

- [ ] **Step 5: Supertonic 설치 확인**

> **HMG 사내망 주의**: 최초 실행 시 HuggingFace에서 모델 ~260MB를 다운로드한다.  
> 사내망에서 막히면 핫스팟이나 외부망에서 `setup-tts.sh`를 먼저 실행할 것.

```bash
./setup-tts.sh
# supertonic 설치 완료 메시지 확인
tts-venv/bin/supertonic --version
```

Expected: `supertonic X.Y.Z` 버전 출력

- [ ] **Step 6: Supertonic 서버 기동 확인**

```bash
bash tts_server/supertonic_start.sh
# 모델 다운로드 완료 대기 (최초 ~3분)
sleep 5
curl -s http://127.0.0.1:7788/health || curl -s http://127.0.0.1:7788/docs | head -5
bash tts_server/supertonic_stop.sh
```

Expected: HTTP 응답 수신 (JSON 또는 HTML)

- [ ] **Step 7: 커밋**

```bash
git add setup-tts.sh tts_server/supertonic_start.sh tts_server/supertonic_stop.sh
git commit -m "feat: supertonic[serve] 설치 및 서버 시작/종료 스크립트 추가"
```

---

## Task 2: voice-map.json 생성

**Files:**
- Create: `voice-map.json`

- [ ] **Step 1: voice-map.json 생성**

프로젝트 루트에 `voice-map.json`을 생성:

```json
{
  "supertonic": {
    "port": 7788,
    "lang": "ko"
  },
  "voices": {
    "reviewer": "M2",
    "planner": "M1",
    "builder": "M4",
    "explorer": "F3",
    "default": "F1"
  },
  "categories": {
    "reviewer": [
      "code-reviewer", "python-reviewer", "security-reviewer",
      "typescript-reviewer", "rust-reviewer", "go-reviewer",
      "kotlin-reviewer", "swift-reviewer", "cpp-reviewer",
      "java-reviewer", "csharp-reviewer", "flutter-reviewer",
      "fastapi-reviewer", "database-reviewer", "mle-reviewer",
      "pr-test-analyzer", "code-simplifier"
    ],
    "planner": [
      "planner", "architect", "code-architect", "a11y-architect",
      "plan", "feature-dev"
    ],
    "builder": [
      "build-error-resolver", "dart-build-resolver", "rust-build-resolver",
      "go-build-resolver", "kotlin-build-resolver", "swift-build-resolver",
      "cpp-build-resolver", "java-build-resolver", "tdd-guide",
      "gan-generator", "multi-execute"
    ],
    "explorer": [
      "Explore", "code-explorer", "general-purpose",
      "gitnexus-exploring", "claude-code-guide"
    ]
  }
}
```

- [ ] **Step 2: 커밋**

```bash
git add voice-map.json
git commit -m "feat: 에이전트 카테고리별 voice 매핑 설정 추가"
```

---

## Task 3: voice-router.ts 구현 (TDD)

**Files:**
- Create: `src/voice-router.ts`
- Create: `tests/voice-router.test.ts`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/voice-router.test.ts`를 생성:

```typescript
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
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npx vitest run tests/voice-router.test.ts
```

Expected: `Cannot find module '../src/voice-router.js'` 오류

- [ ] **Step 3: voice-router.ts 구현**

`src/voice-router.ts`를 생성:

```typescript
// 에이전트 타입을 카테고리·Supertonic voice로 변환하는 라우터
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_VOICE_MAP_PATH = join(__dirname, "..", "voice-map.json");

export interface VoiceMap {
  supertonic: { port: number; lang: string };
  voices: Record<string, string>;
  categories: Record<string, string[]>;
}

const FALLBACK_MAP: VoiceMap = {
  supertonic: { port: 7788, lang: "ko" },
  voices: { default: "F1" },
  categories: {},
};

export function loadVoiceMap(path?: string): VoiceMap {
  const target = path ?? DEFAULT_VOICE_MAP_PATH;
  if (!existsSync(target)) return { ...FALLBACK_MAP };
  try {
    return JSON.parse(readFileSync(target, "utf-8")) as VoiceMap;
  } catch {
    return { ...FALLBACK_MAP };
  }
}

export function resolveVoice(agentType: string, map: VoiceMap): string {
  for (const [category, agents] of Object.entries(map.categories)) {
    if (agents.includes(agentType)) {
      return map.voices[category] ?? map.voices.default ?? "F1";
    }
  }
  return map.voices.default ?? "F1";
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npx vitest run tests/voice-router.test.ts
```

Expected: `5 tests passed`

- [ ] **Step 5: 커밋**

```bash
git add src/voice-router.ts tests/voice-router.test.ts
git commit -m "feat: 에이전트 타입 → voice 변환 라우터 구현"
```

---

## Task 4: config.ts — supertonicPort 추가

**Files:**
- Modify: `src/config.ts`

- [ ] **Step 1: SirenConfig 인터페이스에 supertonicPort 추가**

`src/config.ts`를 수정:

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
  supertonicPort: number;
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
  supertonicPort: 7788,
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

- [ ] **Step 2: 기존 config 테스트 통과 확인**

```bash
npx vitest run tests/config.test.ts
```

Expected: `tests passed` (기존 테스트 전부 통과)

- [ ] **Step 3: 커밋**

```bash
git add src/config.ts
git commit -m "feat: SirenConfig에 supertonicPort 필드 추가"
```

---

## Task 5: player.ts — speakSupertonic() + speakAgent() 추가 (TDD)

**Files:**
- Modify: `src/player.ts`
- Modify: `tests/player.test.ts`

- [ ] **Step 1: player.test.ts에 Supertonic 테스트 추가**

`tests/player.test.ts` 기존 import 블록 아래와 테스트 블록 내부에 다음을 추가:

```typescript
// 기존 import에 추가
import { writeFileSync } from "fs";

// 기존 vi.mock 블록에 추가 (파일 최상단 mock 영역)
vi.mock("fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("fs")>();
  return {
    ...actual,
    writeFileSync: vi.fn(),
    existsSync: vi.fn().mockReturnValue(true),
    unlinkSync: vi.fn(),
  };
});

// 파일 맨 아래에 새 describe 블록 추가
describe("speakAgent", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    (existsSync as ReturnType<typeof vi.fn>).mockReturnValue(true);
  });

  it("Supertonic 서버가 응답하면 WAV를 재생하고 임시 파일을 삭제한다", async () => {
    const fakeWav = Buffer.from("RIFF");
    global.fetch = vi.fn()
      .mockResolvedValueOnce({ ok: true } as Response)          // health
      .mockResolvedValueOnce({                                   // /v1/audio/speech
        ok: true,
        arrayBuffer: async () => fakeWav.buffer,
      } as unknown as Response);

    const spawnMock = vi.fn().mockImplementation((_cmd: string, _args: string[]) => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(spawn).mockImplementation(spawnMock);

    await speakAgent("안녕하세요", "M2", 7788, 1.2);

    expect(writeFileSync).toHaveBeenCalled();
    expect(unlinkSync).toHaveBeenCalled();
  });

  it("Supertonic 서버가 없으면 기존 speak()로 폴백한다", async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error("ECONNREFUSED"));

    const spawnMock = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      const proc = { on: vi.fn() } as any;
      proc.on.mockImplementation((event: string, cb: Function) => {
        if (event === "close") cb(0);
      });
      return proc;
    });
    vi.mocked(spawn).mockImplementation(spawnMock);

    await speakAgent("테스트", "M2", 7788, 1.2);
    // 폴백이 호출되어 프로세스가 실행됐는지 확인
    expect(spawnMock).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npx vitest run tests/player.test.ts
```

Expected: `speakAgent is not exported` 오류

- [ ] **Step 3: player.ts에 speakSupertonic + speakAgent 추가**

`src/player.ts`의 `speak()` 함수 정의 바로 위에 다음 두 함수를 삽입:

```typescript
import { writeFileSync } from "fs";

async function isSuperthonicAlive(port: number): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 500);
    const res = await fetch(`http://localhost:${port}/health`, { signal: ctrl.signal });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

async function speakSupertonic(text: string, voice: string, port: number): Promise<void> {
  const outFile = `/tmp/siren_supertonic_${Date.now()}.wav`;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 15000);
  try {
    const res = await fetch(`http://localhost:${port}/v1/audio/speech`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "supertonic-3",
        input: text,
        voice,
        response_format: "wav",
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error(`Supertonic 응답 오류: ${res.status}`);
    const buf = await res.arrayBuffer();
    writeFileSync(outFile, Buffer.from(buf));
    await spawnPromise("afplay", [outFile]);
  } finally {
    clearTimeout(timer);
    try { unlinkSync(outFile); } catch { /* 임시 파일 정리 실패 무시 */ }
  }
}

export async function speakAgent(
  text: string,
  superthonicVoice: string,
  port: number,
  speed: number,
): Promise<void> {
  if (await isSuperthonicAlive(port)) {
    try {
      await speakSupertonic(text, superthonicVoice, port);
      saveLastMessage(text);
      return;
    } catch {
      // Supertonic 실패 시 기존 체인으로 폴백
    }
  }
  await speak(text, "", speed, "");
}
```

> `writeFileSync` import는 파일 상단 `import { spawn } from "child_process";` 줄 아래의 `import { existsSync, unlinkSync } from "fs";`를 `import { existsSync, unlinkSync, writeFileSync } from "fs";`로 수정.

- [ ] **Step 4: 테스트 통과 확인**

```bash
npx vitest run tests/player.test.ts
```

Expected: `tests passed`

- [ ] **Step 5: 커밋**

```bash
git add src/player.ts tests/player.test.ts
git commit -m "feat: speakSupertonic/speakAgent 추가 — Supertonic HTTP TTS + 폴백"
```

---

## Task 6: index.ts — subagent-stop CLI 분기 추가

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: subagent-stop CLI 분기 삽입**

`src/index.ts`의 `hook` 분기(18번째 줄) 바로 아래에 다음을 삽입:

```typescript
if (process.argv[2] === "subagent-stop") {
  const text = process.argv[3] ?? "";
  const agentType = process.argv[4] ?? "";
  if (text.length >= config.minChars) {
    const { loadVoiceMap, resolveVoice } = await import("./voice-router.js");
    const voiceMap = loadVoiceMap();
    const voice = resolveVoice(agentType, voiceMap);
    const summary = await extractSummary(text, config.summaryModel);
    await speakAgent(summary, voice, voiceMap.supertonic.port, config.ttsSpeed).catch(() => {});
  }
  process.exit(0);
}
```

`import { speak } from "./player.js";` 줄을 다음으로 수정:

```typescript
import { speak, speakAgent } from "./player.js";
```

- [ ] **Step 2: 빌드 확인**

```bash
npm run build 2>&1 | tail -5
```

Expected: 오류 없이 종료

- [ ] **Step 3: 수동 동작 확인**

```bash
# Supertonic 서버 없이도 폴백으로 재생되는지 확인
node dist/index.js subagent-stop "코드 리뷰 결과를 말씀드릴게요. 함수 분리가 필요해 보입니다." "code-reviewer"
```

Expected: TTS 재생 시도 (Supertonic 없으면 EdgeTTS/say로 폴백)

- [ ] **Step 4: 커밋**

```bash
git add src/index.ts
git commit -m "feat: subagent-stop CLI 분기 추가 — 에이전트 타입별 voice 선택"
```

---

## Task 7: hooks/subagent-stop.sh 생성

**Files:**
- Create: `hooks/subagent-stop.sh`

- [ ] **Step 1: subagent-stop.sh 생성**

`hooks/subagent-stop.sh`를 생성:

```bash
#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행

HOOK_DATA=$(cat)

# payload에서 last_assistant_message 추출
TEXT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('last_assistant_message', ''), end='')
except Exception:
    pass
" 2>/dev/null)

if [ -z "$TEXT" ]; then
  exit 0
fi

# payload에서 transcript_path 추출
TRANSCRIPT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# transcript.jsonl에서 가장 최근 Agent 툴 호출의 subagent_type 추출
AGENT_TYPE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  AGENT_TYPE=$(python3 -c "
import json, sys
path = sys.argv[1]
agent_type = ''
try:
    with open(path, 'r') as f:
        lines = f.readlines()
    for line in reversed(lines):
        try:
            entry = json.loads(line)
            content = entry.get('content', [])
            if isinstance(content, list):
                for block in content:
                    if (isinstance(block, dict)
                            and block.get('type') == 'tool_use'
                            and block.get('name') == 'Agent'):
                        agent_type = block.get('input', {}).get('subagent_type', '')
                        if agent_type:
                            break
            if agent_type:
                break
        except Exception:
            continue
except Exception:
    pass
print(agent_type, end='')
" "$TRANSCRIPT" 2>/dev/null)
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" subagent-stop "$TEXT" "$AGENT_TYPE" \
  > /dev/null 2>&1 &
disown $!
exit 0
```

- [ ] **Step 2: 실행 권한 부여**

```bash
chmod +x hooks/subagent-stop.sh
```

- [ ] **Step 3: 수동 테스트**

```bash
echo '{"last_assistant_message":"파이썬 코드에서 예외 처리가 누락되어 있습니다. try-except 블록을 추가하세요.","transcript_path":""}' \
  | bash hooks/subagent-stop.sh
```

Expected: TTS 재생 시작 (백그라운드)

- [ ] **Step 4: 커밋**

```bash
git add hooks/subagent-stop.sh
git commit -m "feat: SubagentStop hook 추가 — transcript 파싱으로 에이전트 타입 감지"
```

---

## Task 8: server.sh — Supertonic 서버 관리 추가

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 상단 변수 블록에 Supertonic 설정 추가**

`server.sh`의 `TTS_PORT=7777` 줄 바로 아래에 다음 두 줄 삽입:

```bash
SUPERTONIC_PORT=7788
SUPERTONIC_PID_FILE="$SCRIPT_DIR/.supertonic.pid"
```

- [ ] **Step 2: _supertonic_running 헬퍼 함수 추가**

`_tts_running()` 함수 정의 바로 아래에 삽입:

```bash
_supertonic_running() {
  [ -f "$SUPERTONIC_PID_FILE" ] && kill -0 "$(cat "$SUPERTONIC_PID_FILE")" 2>/dev/null
}
```

- [ ] **Step 3: do_status에 Supertonic 상태 블록 추가**

`do_status()` 함수 내부의 `# TTS 서버 확인` 블록 바로 아래에 삽입:

```bash
  # Supertonic 서버 확인
  if _supertonic_running; then
    local st_pid
    st_pid=$(cat "$SUPERTONIC_PID_FILE")
    echo "  Supertonic: ✓ 실행 중 (PID: $st_pid, 포트 ${SUPERTONIC_PORT})"
    local st_code
    st_code=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 2 "http://127.0.0.1:${SUPERTONIC_PORT}/health" 2>/dev/null)
    if [[ "$st_code" == "200" ]]; then
      echo "  ST HTTP:    ✓ /health 응답 정상"
    else
      echo "  ST HTTP:    △ /health 미응답 (모델 로딩 중이거나 오류)"
    fi
  else
    echo "  Supertonic: ✗ 중지됨"
  fi
```

- [ ] **Step 4: do_install에 Supertonic 시작 + SubagentStop hook 등록 추가**

`do_install()` 함수 내부의 Stop hook 등록 블록 아래에 삽입:

```bash
  # 2. SubagentStop hook 등록
  echo "SubagentStop hook 등록 중..."
  SUBAGENT_HOOK_CMD="$SCRIPT_DIR/hooks/subagent-stop.sh"
  python3 - "$SETTINGS_JSON" "$SUBAGENT_HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
stop_list = hooks.setdefault("SubagentStop", [])
if any(hook_cmd in str(h) for h in stop_list):
    print("  SubagentStop hook 이미 등록됨 — 스킵")
else:
    stop_list.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 15}]
    })
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ SubagentStop hook 등록 완료")
PYEOF

  # 3. Supertonic 서버 시작
  echo "Supertonic 서버 시작 중..."
  bash "$SCRIPT_DIR/tts_server/supertonic_start.sh"
```

- [ ] **Step 5: do_uninstall에 Supertonic 종료 + SubagentStop hook 제거 추가**

`do_uninstall()` 함수 내부 Stop hook 제거 블록 아래에 삽입:

```bash
  # SubagentStop hook 제거
  echo "SubagentStop hook 제거 중..."
  SUBAGENT_HOOK_CMD="$SCRIPT_DIR/hooks/subagent-stop.sh"
  if [[ -f "$SETTINGS_JSON" ]]; then
    python3 - "$SETTINGS_JSON" "$SUBAGENT_HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
sub = d.get("hooks", {}).get("SubagentStop", [])
before = len(sub)
d["hooks"]["SubagentStop"] = [h for h in sub if hook_cmd not in str(h)]
if len(d["hooks"]["SubagentStop"]) < before:
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ SubagentStop hook 제거 완료")
else:
    print("  SubagentStop hook이 등록되지 않았습니다.")
PYEOF
  fi

  # Supertonic 서버 종료
  if _supertonic_running; then
    echo "Supertonic 서버 종료 중..."
    bash "$SCRIPT_DIR/tts_server/supertonic_stop.sh"
  fi
```

- [ ] **Step 6: 커밋**

```bash
git add server.sh
git commit -m "feat: server.sh에 Supertonic 서버 관리 및 SubagentStop hook 등록 추가"
```

---

## Task 9: 빌드 및 통합 등록

**Files:**
- Build artifacts

- [ ] **Step 1: 전체 빌드**

```bash
npm run build
```

Expected: `dist/` 파일 재생성, 오류 없음

- [ ] **Step 2: 전체 테스트 통과 확인**

```bash
npm test
```

Expected: 모든 테스트 통과

- [ ] **Step 3: install 명령으로 hook + Supertonic 서버 등록**

```bash
./server.sh install
```

Expected:
```
✓ Stop hook 등록 완료
✓ SubagentStop hook 등록 완료
[Supertonic] 서버 시작 (PID ..., 포트 7788, 로그 /tmp/supertonic.log)
✓ chorus 설치 완료
```

- [ ] **Step 4: 상태 확인**

```bash
./server.sh status
```

Expected: Stop hook ✓, SubagentStop hook ✓, Supertonic ✓

- [ ] **Step 5: SubagentStop hook 등록 확인**

```bash
python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
print(json.dumps(d.get('hooks', {}).get('SubagentStop', []), indent=2, ensure_ascii=False))
"
```

Expected: `subagent-stop.sh` 경로가 포함된 hook 항목 출력

- [ ] **Step 6: 통합 동작 수동 확인**

```bash
# Supertonic 서버가 실행 중인 상태에서 시뮬레이션
TRANSCRIPT=$(ls ~/.claude/projects/*/transcripts/*.jsonl 2>/dev/null | tail -1)
echo "{\"last_assistant_message\":\"빌드 오류를 수정했습니다. 누락된 import를 추가하고 타입 오류를 해결했습니다.\",\"transcript_path\":\"${TRANSCRIPT}\"}" \
  | bash hooks/subagent-stop.sh
# 잠시 후 TTS 재생 확인
sleep 3
```

Expected: Supertonic voice로 TTS 재생 (또는 폴백 재생)

- [ ] **Step 7: 최종 커밋**

```bash
git add dist/
git commit -m "feat: 에이전트별 Supertonic 다성 TTS 구현 완료"
```

---

## 자기 검토 (Self-Review)

**Spec 커버리지 확인:**
- [x] SubagentStop hook (Task 7)
- [x] Supertonic HTTP 서버 (Task 1)
- [x] voice-map.json 확장 구조 (Task 2)
- [x] 5개 카테고리 매핑 (Task 2)
- [x] transcript 파싱으로 에이전트 타입 감지 (Task 7)
- [x] 폴백 전략 (Task 5 speakAgent)
- [x] 기존 Stop hook 무변경 (Task 6, 8에서 수정 범위 제한)
- [x] server.sh install/uninstall/status 통합 (Task 8)

**누락 없음. Placeholder 없음.**
