# 2차 개선 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 운영 중 발견된 15건의 버그·품질 이슈를 두 팀(Shell/TypeScript)이 병렬로 수정해 안정성과 유지보수성을 개선한다.

**Architecture:** Shell 팀(A1~A6)과 TypeScript 팀(B1~B8)이 파일 범위가 완전히 분리된 상태로 병렬 작업한다. 두 팀 완료 후 통합 검증(C1)을 실행한다.

**Tech Stack:** Node.js 20+, TypeScript 5, vitest, bash, Python FastAPI(uvicorn), macOS launchd

---

## 파일 변경 범위

| 팀 | 파일 | 담당 항목 |
|---|---|---|
| Shell | `tts_server/tts_player.sh` | D1, S1 |
| Shell | `server.sh` | D1, C2, C3 |
| Shell | `tts_server/supertonic_stop.sh` | C1 |
| Shell | `tts_server/supertonic_start.sh` | S2 |
| TypeScript | `src/config.ts` | Q1 |
| TypeScript | `src/summarizer.ts` | Q2, S3 |
| TypeScript | `src/skill-recommender.ts` | L2 |
| TypeScript | `src/index.ts` | L1, L3 |
| TypeScript | `src/player.ts` | Q3, Q4 |
| TypeScript | `tests/config.test.ts` | Q1 검증 |
| TypeScript | `tests/summarizer.test.ts` | S3 검증 |
| TypeScript | `tests/skill-recommender.test.ts` | L2 검증 |

---

# Section A — Shell 팀

> 작업 디렉토리: `/Users/hmc7102758/Develop/Workspaces/chorus`
> 전제: `npm run build`는 건드리지 않음. Shell 파일만 수정.

---

## Task A1: D1 — TTS Player 중복 실행 방지

**Files:**
- Modify: `tts_server/tts_player.sh`
- Modify: `server.sh`

- [ ] **Step 1: 현재 상태 확인**

```bash
cat tts_server/tts_player.sh | head -20
grep -n "_player_running\|_start_player" server.sh
```

Expected: PID 파일 기반 체크 확인.

- [ ] **Step 2: tts_player.sh — pgrep 중복 방지 추가**

`tts_player.sh`의 `echo $$ > "$PID_FILE"` 바로 아래에 삽입:

```bash
# 자신($$)을 제외한 동일 스크립트 실행 중이면 즉시 종료
EXISTING=$(pgrep -f "tts_player.sh" 2>/dev/null | grep -v "^$$\$" || true)
if [[ -n "$EXISTING" ]]; then
  echo "[TTS Player] 이미 실행 중 (PID $EXISTING) — 중복 실행 방지"
  exit 0
fi
```

- [ ] **Step 3: server.sh — `_player_running()` pgrep 방식으로 교체**

기존:
```bash
_player_running() {
  [ -f "$PLAYER_PID_FILE" ] && kill -0 "$(cat "$PLAYER_PID_FILE")" 2>/dev/null
}
```

교체:
```bash
_player_running() {
  pgrep -f "tts_player.sh" > /dev/null 2>&1
}
```

- [ ] **Step 4: 중복 실행 방지 동작 확인**

```bash
# 첫 번째 player 시작
nohup bash tts_server/tts_player.sh >> /tmp/tts-player.log 2>&1 &
P1=$!
sleep 0.5

# 두 번째 실행 — 즉시 종료되어야 함
bash tts_server/tts_player.sh
sleep 0.3

# 인스턴스 수 확인
COUNT=$(pgrep -c -f "tts_player.sh" 2>/dev/null || echo 0)
echo "실행 중인 TTS Player 수: $COUNT"
# Expected: 1

kill $P1 2>/dev/null; wait $P1 2>/dev/null || true
```

- [ ] **Step 5: 커밋**

```bash
git add tts_server/tts_player.sh server.sh
git commit -m "fix: TTS Player 중복 실행 방지 — pgrep 기반 체크로 동시 발화 해소 (D1)"
```

---

## Task A2: C1 — Supertonic 종료 포트 기반으로 교체

**Files:**
- Modify: `tts_server/supertonic_stop.sh`

- [ ] **Step 1: 현재 코드 확인**

```bash
cat tts_server/supertonic_stop.sh
```

Expected: `.supertonic.pid` 파일 기반 종료 로직 확인.

- [ ] **Step 2: 포트 기반 종료로 전체 교체**

`tts_server/supertonic_stop.sh` 전체를 아래로 교체:

```bash
#!/usr/bin/env bash
# Supertonic TTS 서버 종료 스크립트 — 포트 점유 기반
PORT=7788
PID=$(lsof -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null && echo "[Supertonic] 서버 종료 (PID $PID, 포트 $PORT)" || true
else
    echo "[Supertonic] 실행 중인 서버 없음 (포트 $PORT)"
fi
```

- [ ] **Step 3: 동작 확인**

```bash
# Supertonic이 실행 중이 아닌 상태에서 종료 시도
bash tts_server/supertonic_stop.sh
# Expected: "[Supertonic] 실행 중인 서버 없음 (포트 7788)"

# Supertonic 시작 후 종료
bash tts_server/supertonic_start.sh
sleep 2
bash tts_server/supertonic_stop.sh
sleep 1
lsof -iTCP:7788 -t 2>/dev/null || echo "7788 해제 확인"
```

- [ ] **Step 4: 커밋**

```bash
git add tts_server/supertonic_stop.sh
git commit -m "fix: supertonic_stop.sh PID 파일 → 포트 기반 종료로 교체 (C1) — P6 회귀 수정"
```

---

## Task A3: C3 — do_stop launchd 관리 서버 정상 종료

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 현재 do_stop 확인**

```bash
grep -n "do_stop\|launchd\|stop.sh" server.sh | head -30
```

- [ ] **Step 2: do_stop 함수 launchd 인식으로 수정**

`server.sh`의 `do_stop()` 함수에서 `bash "$SCRIPT_DIR/tts_server/stop.sh"` 직전에 launchd 체크 추가:

기존 `do_stop()` 끝부분:
```bash
  if ! _tts_running; then
    echo "TTS 서버가 실행 중이지 않습니다."
    return 0
  fi
  bash "$SCRIPT_DIR/tts_server/stop.sh"
```

교체:
```bash
  if ! _tts_running; then
    echo "TTS 서버가 실행 중이지 않습니다."
    return 0
  fi
  if _is_launchd_managed; then
    echo "launchd 관리 서버 종료 중 (launchctl stop)..."
    launchctl stop "$LAUNCHD_LABEL"
    local i=0
    while (( i < 8 )); do
      _tts_running || break
      sleep 1
      i=$(( i + 1 ))
    done
    return 0
  fi
  bash "$SCRIPT_DIR/tts_server/stop.sh"
```

- [ ] **Step 3: 동작 확인 (launchd 미설치 상태)**

```bash
# 현재 launchd 미설치이므로 기존 경로 동작 확인
bash tts_server/start.sh
sleep 1
./server.sh stop
sleep 1
lsof -iTCP:7777 -t 2>/dev/null || echo "7777 해제 확인"
# Expected: 7777 해제 확인
bash tts_server/start.sh  # 이후 작업을 위해 재시작
```

- [ ] **Step 4: 커밋**

```bash
git add server.sh
git commit -m "fix: do_stop launchd 관리 서버는 launchctl stop 사용 (C3)"
```

---

## Task A4: C2 — do_install LaunchAgent 환경변수 보완

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 현재 plist EnvironmentVariables 섹션 확인**

```bash
grep -A 15 "EnvironmentVariables" server.sh
```

Expected: `HF_HUB_OFFLINE`과 `PATH`만 포함됨.

- [ ] **Step 2: plist 생성 시 HUB_* 환경변수 포함하도록 수정**

`server.sh`의 plist `EnvironmentVariables` 섹션 교체:

기존:
```xml
  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${SCRIPT_DIR}/tts-venv/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
```

교체 (PLIST_EOF 히어닥 내부이므로 `${}` 확장이 동작함):
```xml
  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${SCRIPT_DIR}/tts-venv/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HUB_BASE_URL</key>
    <string>${HUB_BASE_URL:-}</string>
    <key>HUB_API_KEY</key>
    <string>${HUB_API_KEY:-}</string>
    <key>HUB_PROJECT_ID</key>
    <string>${HUB_PROJECT_ID:-}</string>
    <key>SIREN_VENV_PYTHON</key>
    <string>${SIREN_VENV_PYTHON:-}</string>
  </dict>
```

- [ ] **Step 3: do_install 실행 후 plist 내용 확인 (선택적)**

```bash
# 설치 없이 plist 내용만 미리 확인하려면:
grep "HUB_API_KEY\|HUB_BASE_URL\|HUB_PROJECT_ID" server.sh
# Expected: 네 줄 모두 표시됨
```

- [ ] **Step 4: 커밋**

```bash
git add server.sh
git commit -m "fix: do_install LaunchAgent plist에 HUB_* 환경변수 포함 (C2)"
```

---

## Task A5: S2 — supertonic_start.sh race condition 제거

**Files:**
- Modify: `tts_server/supertonic_start.sh`

- [ ] **Step 1: 현재 코드 확인**

```bash
cat tts_server/supertonic_start.sh
```

Expected: `sleep 1` + `kill -0 $BGPID` 블록 확인.

- [ ] **Step 2: sleep 1 / kill -0 블록 제거**

`supertonic_start.sh`에서 아래 블록 삭제:

```bash
sleep 1
if ! kill -0 "$BGPID" 2>/dev/null; then
    echo "[Supertonic] 서버 시작 실패. 로그를 확인하세요: $LOG_FILE" >&2
    exit 1
fi
```

30초 루프가 실제 헬스체크를 담당하므로 중간 검사는 불필요.

- [ ] **Step 3: 동작 확인**

```bash
# 이미 실행 중인 Supertonic 종료 후 재시작 테스트
bash tts_server/supertonic_stop.sh
sleep 1
bash tts_server/supertonic_start.sh
# Expected: "[Supertonic] 서버 준비 완료 (N초)"
```

- [ ] **Step 4: 커밋**

```bash
git add tts_server/supertonic_start.sh
git commit -m "refactor: supertonic_start.sh sleep 1 + kill -0 오해 소지 블록 제거 (S2)"
```

---

## Task A6: S1 — tts_player.sh 배열 파싱 안전화

**Files:**
- Modify: `tts_server/tts_player.sh`

- [ ] **Step 1: 현재 코드 확인**

```bash
grep -n "ls -1\|files=" tts_server/tts_player.sh
```

Expected: `files=($(ls -1 ...))` 패턴 확인.

- [ ] **Step 2: cleanup 함수 내 ls 배열 → mapfile 교체**

`_cleanup_stale()` 내 파일 수 제한 블록:

기존:
```bash
  local files
  files=($(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort || true))
  local count=${#files[@]}
  if (( count > MAX_FILES )); then
    local excess=$(( count - MAX_FILES ))
    for f in "${files[@]:0:$excess}"; do
      rm -f "$f" "${f%.*}.meta"
    done
  fi
```

교체:
```bash
  local files=()
  mapfile -t files < <(find "$SPOOL" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | sort)
  local count=${#files[@]}
  if (( count > MAX_FILES )); then
    local excess=$(( count - MAX_FILES ))
    for f in "${files[@]:0:$excess}"; do
      rm -f "$f" "${f%.*}.meta"
    done
  fi
```

- [ ] **Step 3: 메인 루프 audio 선택도 교체**

기존:
```bash
  audio=$(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort | head -1 || true)
```

교체:
```bash
  audio=$(find "$SPOOL" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | sort | head -1 || true)
```

- [ ] **Step 4: 동작 확인**

```bash
# tts_player.sh가 실행 중이면 종료 후 재시작
pkill -f tts_player.sh 2>/dev/null || true
sleep 0.5
nohup bash tts_server/tts_player.sh >> /tmp/tts-player.log 2>&1 &
sleep 1
pgrep -f tts_player.sh && echo "Player 정상 실행 중"
```

- [ ] **Step 5: 커밋**

```bash
git add tts_server/tts_player.sh
git commit -m "refactor: tts_player.sh ls 배열 파싱 → find + mapfile로 안전화 (S1)"
```

---

# Section B — TypeScript 팀

> 작업 디렉토리: `/Users/hmc7102758/Develop/Workspaces/chorus`
> 모든 스텝 후 `npm test` 로 71개 테스트 통과 확인.

---

## Task B1: Q1 — SirenConfig 미사용 필드 제거

**Files:**
- Modify: `src/config.ts`
- Modify: `tests/config.test.ts`

- [ ] **Step 1: 실패 테스트 작성**

`tests/config.test.ts` 마지막 `describe` 블록 뒤에 추가:

```typescript
describe("SirenConfig — 미사용 필드 제거", () => {
  it("기본 설정에 ttsModel 없음", () => {
    const c = loadConfig("/nonexistent/should-not-exist.json");
    expect((c as Record<string, unknown>).ttsModel).toBeUndefined();
  });

  it("기본 설정에 language 없음", () => {
    const c = loadConfig("/nonexistent/should-not-exist.json");
    expect((c as Record<string, unknown>).language).toBeUndefined();
  });
});
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/config.test.ts
```

Expected: 새 두 테스트 FAIL (`ttsModel`·`language`가 현재 반환됨).

- [ ] **Step 3: config.ts에서 두 필드 제거**

`src/config.ts`의 `SirenConfig` 인터페이스에서:
```typescript
  ttsModel: string;   // ← 삭제
  language: string;   // ← 삭제
```

`DEFAULTS` 객체에서:
```typescript
  ttsModel: "tts-1",  // ← 삭제
  language: "ko",     // ← 삭제
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npx vitest run tests/config.test.ts
```

Expected: 모든 테스트 PASS.

- [ ] **Step 5: 전체 테스트**

```bash
npm test
```

Expected: 73 tests passed (기존 71 + 신규 2).

- [ ] **Step 6: 커밋**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "refactor: SirenConfig에서 미사용 ttsModel·language 필드 제거 (Q1)"
```

---

## Task B2: Q2 — getDefaultModel() 일관성 통일

**Files:**
- Modify: `src/summarizer.ts`

- [ ] **Step 1: 현재 코드 확인**

```bash
grep -n "model = " src/summarizer.ts
grep -n "getDefaultModel\|gpt-5.4" src/summarizer.ts src/llm-client.ts
```

Expected: `summarizer.ts`에 `model = "gpt-5.4"` 하드코딩 두 곳.

- [ ] **Step 2: summarizer.ts import에 getDefaultModel 추가**

`src/summarizer.ts` 상단 import 수정:

기존:
```typescript
import { makeHubClient } from "./llm-client.js";
```

교체:
```typescript
import { makeHubClient, getDefaultModel } from "./llm-client.js";
```

- [ ] **Step 3: 두 함수 기본값 교체**

`extractOneLiner` 시그니처:
```typescript
export async function extractOneLiner(text: string, model = getDefaultModel()): Promise<string> {
```

`extractSummary` 시그니처:
```typescript
export async function extractSummary(text: string, model = getDefaultModel()): Promise<string> {
```

- [ ] **Step 4: 빌드 + 테스트**

```bash
npm run build && npm test
```

Expected: 빌드 성공, 73 tests passed.

- [ ] **Step 5: 커밋**

```bash
git add src/summarizer.ts
git commit -m "refactor: summarizer 모델 기본값 getDefaultModel()로 통일 (Q2)"
```

---

## Task B3: L2 — transcript content 배열 파싱 수정

**Files:**
- Modify: `src/skill-recommender.ts`
- Modify: `tests/skill-recommender.test.ts`

- [ ] **Step 1: 실패 테스트 작성**

`tests/skill-recommender.test.ts`의 `readRecentTranscripts — 기본 동작` describe 블록 안에 추가:

```typescript
  it("content가 배열일 때 text 필드만 추출하고 [object Object] 반환 안 함", () => {
    vi.mocked(fs.existsSync).mockReturnValue(true);
    vi.mocked(fs.readdirSync).mockReturnValue(["session.jsonl"] as any);
    vi.mocked(fs.statSync).mockReturnValue({ mtimeMs: Date.now() } as any);
    vi.mocked(fs.readFileSync).mockReturnValue(
      JSON.stringify({
        type: "assistant",
        content: [
          { type: "text", text: "배열 콘텐츠 메시지" },
          { type: "tool_use", id: "x", name: "Bash", input: {} },
        ],
      }) + "\n"
    );
    _resetTranscriptCache();
    const result = readRecentTranscripts("/fake/transcripts");
    expect(result).toContain("배열 콘텐츠 메시지");
    expect(result).not.toContain("[object Object]");
  });
```

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/skill-recommender.test.ts
```

Expected: 새 테스트 FAIL (`[object Object]` 포함).

- [ ] **Step 3: extractContent 헬퍼 추가 및 적용**

`src/skill-recommender.ts`의 `readRecentTranscripts` 함수 내부 content 처리 로직 수정:

파일 내 `readRecentTranscripts` 함수를 찾아 content 추출 부분을 아래로 교체:

기존:
```typescript
            try {
              const entry = JSON.parse(line);
              const content = String(entry.content ?? "").slice(0, 300);
              if (entry.type === "user") return `User: ${content}`;
              if (entry.type === "assistant") return `Assistant: ${content}`;
              return null;
            } catch {
```

교체:
```typescript
            try {
              const entry = JSON.parse(line);
              const content = extractContent(entry.content);
              if (entry.type === "user") return `User: ${content}`;
              if (entry.type === "assistant") return `Assistant: ${content}`;
              return null;
            } catch {
```

`readRecentTranscripts` 함수 **위**에 헬퍼 함수 추가:

```typescript
function extractContent(raw: unknown): string {
  if (typeof raw === "string") return raw.slice(0, 300);
  if (Array.isArray(raw)) {
    return raw
      .filter(
        (b): b is { type: string; text: string } =>
          typeof b === "object" && b !== null && typeof (b as Record<string, unknown>).text === "string"
      )
      .map((b) => b.text)
      .join(" ")
      .slice(0, 300);
  }
  return "";
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npx vitest run tests/skill-recommender.test.ts
```

Expected: 모든 테스트 PASS.

- [ ] **Step 5: 전체 테스트**

```bash
npm test
```

Expected: 74 tests passed.

- [ ] **Step 6: 커밋**

```bash
git add src/skill-recommender.ts tests/skill-recommender.test.ts
git commit -m "fix: readRecentTranscripts content 배열 파싱 — [object Object] 방지 (L2)"
```

---

## Task B4: L1 — autoSpeak false 시 hook 실행 차단

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: 현재 hook 분기 확인**

```bash
grep -n "autoSpeak\|minChars\|process.argv\[2\]" src/index.ts | head -15
```

- [ ] **Step 2: hook 분기에 autoSpeak 체크 추가**

`src/index.ts`의 hook CLI 분기:

기존:
```typescript
if (process.argv[2] === "hook") {
  const text = await readStdin();
  if (text.length >= config.minChars) {
```

교체:
```typescript
if (process.argv[2] === "hook") {
  const text = await readStdin();
  if (!config.autoSpeak || text.length < config.minChars) {
    process.exit(0);
  }
  if (true) {  // autoSpeak && length >= minChars
```

아래 `process.exit(0)` 앞에 닫힘 괄호 추가가 필요하므로, 전체 블록:

```typescript
if (process.argv[2] === "hook") {
  const text = await readStdin();
  if (config.autoSpeak && text.length >= config.minChars) {
    const summary = await extractSummary(text, config.summaryModel);
    await speakHook(summary, config.voice, config.ttsSpeed).catch(() => {});
  }
  process.exit(0);
}
```

- [ ] **Step 3: 빌드 확인**

```bash
npm run build
```

Expected: 빌드 성공.

- [ ] **Step 4: 동작 확인**

```bash
# autoSpeak false 시 TTS 미실행 확인
echo '{"autoSpeak": false}' > /tmp/test-autospeak.json
SIREN_CONFIG=/tmp/test-autospeak.json node dist/index.js hook <<< "이것은 autoSpeak false 테스트입니다"
echo "exit: $?"
# Expected: 즉시 exit 0, afplay 호출 없음
rm /tmp/test-autospeak.json
```

- [ ] **Step 5: 전체 테스트**

```bash
npm test
```

Expected: 74 tests passed (index.ts 변경은 기존 테스트에 영향 없음).

- [ ] **Step 6: 커밋**

```bash
git add src/index.ts
git commit -m "fix: autoSpeak false 시 Stop hook TTS 실행 차단 (L1)"
```

---

## Task B5: L3 — hook-suggest 컨텍스트 소스 정리

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: 현재 hook-suggest 분기 확인**

```bash
grep -n "hook-suggest\|process.argv\[3\]" src/index.ts
```

Expected: `process.argv[3] ?? readRecentTranscripts()` 패턴.

- [ ] **Step 2: hook-suggest 분기 수정**

기존:
```typescript
if (process.argv[2] === "hook-suggest") {
  const context = process.argv[3] ?? readRecentTranscripts();
  const rec = await recommendSkill(context, false, config.skillCooldownMinutes, config.summaryModel);
```

교체:
```typescript
if (process.argv[2] === "hook-suggest") {
  const transcripts = readRecentTranscripts();
  const promptHint = process.argv[3]
    ? `\n[현재 입력]: ${String(process.argv[3]).slice(0, 200)}`
    : "";
  const context = transcripts + promptHint;
  const rec = await recommendSkill(context, false, config.skillCooldownMinutes, config.summaryModel);
```

- [ ] **Step 3: 빌드 + 테스트**

```bash
npm run build && npm test
```

Expected: 빌드 성공, 74 tests passed.

- [ ] **Step 4: 커밋**

```bash
git add src/index.ts
git commit -m "fix: hook-suggest 컨텍스트를 transcript+프롬프트 힌트로 통일 (L3)"
```

---

## Task B6: S3 — sanitizeForSpeech 문장 부호 보존

**Files:**
- Modify: `src/summarizer.ts`
- Modify: `tests/summarizer.test.ts`

- [ ] **Step 1: 실패 테스트 작성**

`tests/summarizer.test.ts`에서 sanitizeForSpeech 간접 테스트 (`extractOneLiner` 경유):

```typescript
describe("sanitizeForSpeech — 문장 부호 보존", () => {
  it("? ! 가 보존되어야 한다", async () => {
    const { extractOneLiner } = await import("../src/summarizer.js");
    // sanitizeForSpeech를 직접 테스트하기 위해 짧은 텍스트로 LLM 폴백 유도
    // openai mock이 빈 응답 반환 → fallback() → sanitizeForSpeech 호출
    const result = await extractOneLiner("테스트입니다! 정말인가요?");
    expect(result).toMatch(/[!?]/);
  });
});
```

참고: 현재 `summarizer.test.ts`에서 openai는 mock됨. `extractOneLiner` 호출 시 LLM 실패 → `fallback()` → `sanitizeForSpeech()` 호출.

- [ ] **Step 2: 실패 확인**

```bash
npx vitest run tests/summarizer.test.ts
```

Expected: 새 테스트 FAIL (현재 `?`·`!` 제거됨).

- [ ] **Step 3: sanitizeForSpeech 정규식 수정**

`src/summarizer.ts`의 `sanitizeForSpeech`:

기존:
```typescript
function sanitizeForSpeech(text: string): string {
  return text
    .replace(/[^\p{L}\p{N}\s,.。:]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}
```

교체:
```typescript
function sanitizeForSpeech(text: string): string {
  return text
    .replace(/[^\p{L}\p{N}\s,.!?。:]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
npx vitest run tests/summarizer.test.ts
```

Expected: 모든 테스트 PASS.

- [ ] **Step 5: 전체 테스트**

```bash
npm test
```

Expected: 75 tests passed.

- [ ] **Step 6: 커밋**

```bash
git add src/summarizer.ts tests/summarizer.test.ts
git commit -m "fix: sanitizeForSpeech에서 ? ! 보존 — 억양 단서 유지 (S3)"
```

---

## Task B7: Q3 — Spool 파일명 충돌 방지

**Files:**
- Modify: `src/player.ts`

- [ ] **Step 1: 현재 enqueueSpool 확인**

```bash
grep -n "enqueueSpool\|Date.now\|SPOOL_DIR" src/player.ts | head -15
```

- [ ] **Step 2: enqueueSpool 유일성 강화**

`src/player.ts`의 `enqueueSpool` 함수:

기존:
```typescript
function enqueueSpool(tmpFile: string, speed: number): void {
  const ts = Date.now();
  const ext = tmpFile.split(".").pop() ?? "wav";
  ensureSpoolDir();
  renameSync(tmpFile, `${SPOOL_DIR}/${ts}.${ext}`);
  writeFileSync(`${SPOOL_DIR}/${ts}.meta`, String(speed));
}
```

교체:
```typescript
function enqueueSpool(tmpFile: string, speed: number): void {
  const ts = Date.now();
  const rand = Math.random().toString(36).slice(2, 7);
  const uid = `${ts}_${rand}`;
  const ext = tmpFile.split(".").pop() ?? "wav";
  ensureSpoolDir();
  renameSync(tmpFile, `${SPOOL_DIR}/${uid}.${ext}`);
  writeFileSync(`${SPOOL_DIR}/${uid}.meta`, String(speed));
}
```

- [ ] **Step 3: 빌드 + 테스트**

```bash
npm run build && npm test
```

Expected: 빌드 성공, 75 tests passed.

- [ ] **Step 4: 커밋**

```bash
git add src/player.ts
git commit -m "fix: spool 파일명 ts+rand 조합으로 충돌 방지 (Q3)"
```

---

## Task B8: Q4 — withTTSLock 지수 백오프

**Files:**
- Modify: `src/player.ts`

- [ ] **Step 1: 현재 withTTSLock 폴링 확인**

```bash
grep -n "LOCK_WAIT_MS\|setTimeout.*300\|withTTSLock" src/player.ts | head -20
```

Expected: `setTimeout(r, 300)` 고정 폴링 확인.

- [ ] **Step 2: 지수 백오프 적용**

`src/player.ts`의 `withTTSLock` 함수에서 폴링 부분:

기존:
```typescript
      if (Date.now() > deadline) return undefined; // 타임아웃 — 스킵
      await new Promise(r => setTimeout(r, 300));
```

교체:
```typescript
      if (Date.now() > deadline) return undefined; // 타임아웃 — 스킵
      await new Promise(r => setTimeout(r, delay));
      delay = Math.min(Math.floor(delay * 1.5), 1000);
```

그리고 `while (!acquired)` 루프 **직전**에 `delay` 변수 초기화 추가:

```typescript
  let delay = 100;
  while (!acquired) {
```

- [ ] **Step 3: 빌드 + 테스트**

```bash
npm run build && npm test
```

Expected: 빌드 성공, 75 tests passed.

- [ ] **Step 4: 커밋**

```bash
git add src/player.ts
git commit -m "perf: withTTSLock 고정 300ms 폴링 → 지수 백오프 100~1000ms (Q4)"
```

---

# Section C — 통합 검증

## Task C1: 전체 통합 검증 및 마무리

> Shell 팀·TypeScript 팀 모든 작업 완료 후 실행.

- [ ] **Step 1: TypeScript 전체 테스트**

```bash
npm test
```

Expected: 75 tests passed, 0 failed.

- [ ] **Step 2: Python 테스트**

```bash
cd /Users/hmc7102758/Develop/Workspaces/chorus
python3 -m pytest tts_server/test_server.py -v
```

Expected: 모든 테스트 PASS.

- [ ] **Step 3: 서버 상태 확인**

```bash
./server.sh status
```

Expected:
```
TTS 서버:   ✓ 실행 중
TTS Player: ✓ 실행 중 (스풀 대기: 0개)
Supertonic: ✓ 실행 중
Stop hook:  ✓ 등록됨
```

- [ ] **Step 4: TTS Player 단일 실행 확인**

```bash
COUNT=$(pgrep -c -f "tts_player.sh" 2>/dev/null || echo 0)
echo "TTS Player 인스턴스 수: $COUNT"
# Expected: 1
```

- [ ] **Step 5: Supertonic 종료 동작 확인**

```bash
bash tts_server/supertonic_stop.sh
sleep 1
lsof -iTCP:7788 -t 2>/dev/null || echo "7788 해제 확인"
bash tts_server/supertonic_start.sh
```

Expected: 포트 7788 해제 후 재시작 성공.

- [ ] **Step 6: autoSpeak 동작 확인**

```bash
printf '{"autoSpeak": false}' > /tmp/test-siren-autospeak.json
SIREN_CONFIG=/tmp/test-siren-autospeak.json \
  node dist/index.js hook <<< "autoSpeak false 테스트 문장입니다. 이 텍스트는 발화되면 안 됩니다."
echo "exit $? — 발화 없이 종료 확인"
rm /tmp/test-siren-autospeak.json
```

- [ ] **Step 7: 커밋 이력 확인**

```bash
git log --oneline -15
```

Expected: A1~A6, B1~B8 커밋 모두 확인.

- [ ] **Step 8: 최종 통합 커밋 (필요 시)**

```bash
git log --oneline origin/main..HEAD
# 모든 작업 커밋이 올바르게 표시되면 완료
```
