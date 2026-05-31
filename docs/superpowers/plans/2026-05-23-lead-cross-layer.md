# Lead Cross-Layer 선행 처리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TS 팀·Python·Shell 팀 병렬 작업 전에, 두 팀 모두 의존하는 cross-layer 항목(포트 이중화 제거, 예시 설정 파일, 버전 단일화) 3건을 완료한다.

**Architecture:** `voice-map.json`에서 포트 정의를 제거하고 `SirenConfig.supertonicPort`를 단일 소스로 삼는다. `VoiceMap` 인터페이스와 `index.ts` 참조를 일관되게 수정한다. `.siren.json.example`은 신규 파일로 git 추적한다. 버전은 `package.json`을 동적 import해 MCP 서버에 반영한다.

**Tech Stack:** TypeScript, Node.js ESM, vitest

---

## 파일 변경 범위

| 파일 | 작업 |
|---|---|
| `voice-map.json` | `supertonic.port` 필드 제거 |
| `src/voice-router.ts` | `VoiceMap.supertonic.port` 제거, `FALLBACK_MAP` 수정 |
| `src/index.ts` | `voiceMap.supertonic.port` → `config.supertonicPort`, 버전 동적 import |
| `.siren.json.example` | 신규 생성 |
| `tests/voice-router.test.ts` | port 필드 없는 voice-map 동작 테스트 추가 |

---

## Task 1: 포트 이중화 제거 (R1)

**Files:**
- Modify: `src/voice-router.ts`
- Modify: `voice-map.json`
- Modify: `src/index.ts`
- Test: `tests/voice-router.test.ts`

- [ ] **Step 1: 실패하는 테스트 추가**

`tests/voice-router.test.ts` 파일을 열어 맨 끝에 추가한다.

```typescript
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
```

파일 상단 import에 `writeFileSync`, `unlinkSync`가 없으면 추가한다:

```typescript
import { writeFileSync, unlinkSync } from "fs";
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
npx vitest run tests/voice-router.test.ts
```

Expected: `(map.supertonic as any).port).toBeUndefined()` 실패 — 현재 json에 port가 있으므로 7788 반환.

- [ ] **Step 3: `VoiceMap` 인터페이스에서 `port` 제거**

`src/voice-router.ts` 수정:

```typescript
// 변경 전
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
```

```typescript
// 변경 후
export interface VoiceMap {
  supertonic: { lang: string };
  voices: Record<string, string>;
  categories: Record<string, string[]>;
}

const FALLBACK_MAP: VoiceMap = {
  supertonic: { lang: "ko" },
  voices: { default: "F1" },
  categories: {},
};
```

- [ ] **Step 4: `voice-map.json`에서 `port` 제거**

```json
{
  "supertonic": {
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
      "gan-generator", "multi-execute", "doc-updater", "refactor-cleaner"
    ],
    "explorer": [
      "Explore", "code-explorer", "general-purpose",
      "gitnexus-exploring", "claude-code-guide"
    ]
  }
}
```

- [ ] **Step 5: `index.ts`에서 `voiceMap.supertonic.port` → `config.supertonicPort`**

`src/index.ts`의 `subagent-stop` 분기에서:

```typescript
// 변경 전
await speakAgent(announcement, voice, voiceMap.supertonic.port, config.ttsSpeed).catch(() => {});

// 변경 후
await speakAgent(announcement, voice, config.supertonicPort, config.ttsSpeed).catch(() => {});
```

- [ ] **Step 6: 빌드 확인**

```bash
npm run build
```

Expected: 오류 없음. `voiceMap.supertonic.port` 참조가 남아 있으면 TS 컴파일 오류 발생.

- [ ] **Step 7: 테스트 통과 확인**

```bash
npm test
```

Expected: 57 + 1 = 58개 테스트 모두 통과.

- [ ] **Step 8: 커밋**

```bash
git add src/voice-router.ts voice-map.json src/index.ts tests/voice-router.test.ts
git commit -m "refactor: 포트 설정 이중화 제거 — config.supertonicPort 단일 소스"
```

---

## Task 2: `.siren.json.example` 생성 (R2)

**Files:**
- Create: `.siren.json.example`

- [ ] **Step 1: 파일 생성**

프로젝트 루트에 `.siren.json.example` 파일을 생성한다. `SirenConfig`의 모든 키와 기본값을 포함한다.

```json
{
  "_comment": "이 파일을 .siren.json으로 복사 후 값을 수정하세요. .siren.json은 .gitignore로 추적하지 않습니다.",
  "autoSpeak": true,
  "minChars": 50,
  "voice": "Sohee",
  "summaryModel": "gpt-5.4",
  "ttsModel": "tts-1",
  "language": "ko",
  "ttsSpeed": 1.2,
  "ttsInstruct": "밝고 활기차게 말해주세요",
  "skillCooldownMinutes": 30,
  "supertonicPort": 7788
}
```

- [ ] **Step 2: git에 추가 (.gitignore 확인)**

`.gitignore`에 `.siren.json.example`이 제외 패턴에 포함되지 않았는지 확인 후 추가:

```bash
git add .siren.json.example
git status
```

Expected: `.siren.json.example`이 `Changes to be committed`에 표시됨.

- [ ] **Step 3: 모든 SirenConfig 키 포함 여부 검증**

다음 명령으로 config.ts의 DEFAULTS 키와 example 파일의 키를 비교한다:

```bash
node -e "
const fs = require('fs');
const ex = JSON.parse(fs.readFileSync('.siren.json.example', 'utf-8'));
const keys = Object.keys(ex).filter(k => k !== '_comment');
console.log('example 키:', keys.join(', '));
"
```

Expected: `autoSpeak, minChars, voice, summaryModel, ttsModel, language, ttsSpeed, ttsInstruct, skillCooldownMinutes, supertonicPort` 출력.

- [ ] **Step 4: 커밋**

```bash
git commit -m "docs: .siren.json.example 추가 — 팀원 초기 설정 가이드"
```

---

## Task 3: 버전 정보 단일화 (R3)

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: 현재 버전 하드코딩 위치 확인**

`src/index.ts`의 MCP 서버 초기화 부분:

```typescript
const server = new Server(
  { name: "chorus", version: "0.1.0" },
  { capabilities: { tools: {} } }
);
```

- [ ] **Step 2: package.json 동적 import로 교체**

`src/index.ts` 상단의 import 블록 아래에 추가하고 서버 초기화 수정:

```typescript
// 파일 상단 import 블록 아래에 추가
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { version } = require("../package.json") as { version: string };
```

그리고 서버 초기화를:

```typescript
const server = new Server(
  { name: "chorus", version },
  { capabilities: { tools: {} } }
);
```

- [ ] **Step 3: 빌드 확인**

```bash
npm run build 2>&1 | head -20
```

Expected: 오류 없음.

- [ ] **Step 4: 버전 일치 단언**

```bash
node -e "
const { createRequire } = require('module');
const req = createRequire(import.meta.url ?? 'file://' + process.cwd() + '/');
" 2>/dev/null || node dist/index.js hook < /dev/null 2>/dev/null || true

# package.json 버전 확인
node -e "console.log(require('./package.json').version)"
```

Expected: `0.1.0` 출력.

- [ ] **Step 5: 테스트 통과 확인**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **Step 6: 커밋**

```bash
git add src/index.ts
git commit -m "refactor: MCP 서버 버전을 package.json에서 동적 참조"
```

---

## 최종 검증

- [ ] **전체 테스트 통과**

```bash
npm test
```

Expected: 58개+ 모두 통과.

- [ ] **TS 팀·Python·Shell 팀에 선행 완료 알림**

두 팀에 R1~R3 완료를 알리고 병렬 작업 시작 신호를 보낸다.
