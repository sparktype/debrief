# summary-voice-mcp 2차 개선 설계

**날짜**: 2026-05-24  
**작성자**: 리드 에이전트 (박상선 책임매니저)  
**상태**: 초안  
**기반**: 1차 개선(19건) 완료 이후 재분석

---

## 배경

1차 개선 19건이 모두 완료되어 71개 테스트가 통과하는 안정된 상태에서 재분석을 수행했다.
분석 결과 14건의 이슈가 도출됐다. 이 중 3건은 운영에 실제 영향을 주는 버그이며,
P6(Supertonic 상태 확인 포트 방식으로 교체)의 사이드이펙트로 발생한 회귀(C1)가 포함된다.

---

## 팀 구성

| 팀 | 담당 항목 | 파일 범위 |
|---|---|---|
| Shell 팀 | C1·C2·C3·S1·S2 (5건) | `server.sh`, `tts_server/supertonic_stop.sh`, `tts_server/supertonic_start.sh`, `tts_server/tts_player.sh` |
| TypeScript 팀 | L1·L2·L3·Q1·Q2·Q3·Q4·S3 (8건) | `src/` 전체 |

두 팀은 파일 범위가 겹치지 않아 완전 병렬 실행 가능.  
S3(`sanitizeForSpeech`)는 `src/summarizer.ts`(TypeScript) 수정이므로 TypeScript 팀 담당.

---

## Shell 팀 항목

### C1 — Supertonic 종료 불가 (HIGH, 1차 P6 회귀)

**문제**: `supertonic_stop.sh`는 `.supertonic.pid` 파일로 종료하는데,
`supertonic_start.sh`는 PID 파일을 생성하지 않는다.
1차 개선 P6에서 running check를 포트 기반으로 바꾸었지만 stop 스크립트를 함께 수정하지 않았다.
결과: `server.sh stop`으로 Supertonic을 멈출 수 없다.

**해결**: `supertonic_stop.sh`를 포트 기반 kill로 교체.
```bash
PID=$(lsof -iTCP:7788 -sTCP:LISTEN -t 2>/dev/null | head -1)
if [[ -n "$PID" ]]; then kill "$PID"; fi
```

**테스트**: 포트 점유 프로세스가 kill로 종료됨 확인.

---

### C2 — LaunchAgent 재시작 후 LLM 미동작 (HIGH)

**문제**: plist `EnvironmentVariables`에 `HUB_API_KEY`, `HUB_BASE_URL`, `HUB_PROJECT_ID` 미포함.
launchd auto-restart 시 환경변수 없이 시작 → LLM 요약이 항상 규칙 기반 폴백으로 동작.

**해결**: `do_install`에서 plist 생성 시 현재 환경변수 값을 `EnvironmentVariables`에 포함.
없는 값은 빈 문자열로 placeholder 기입.

**변경 파일**: `server.sh`

---

### C3 — `do_stop`이 launchd 관리 서버를 중지 못함 (HIGH)

**문제**: `do_stop`은 `tts_server/stop.sh`를 직접 호출해 프로세스를 kill한다.
launchd `KeepAlive.SuccessfulExit=false` 설정으로 kill 후 즉시 재시작됨.

**해결**: `do_stop` 시작 시 `_is_launchd_managed` 확인 → launchd 관리 중이면
`launchctl stop $LAUNCHD_LABEL`으로 요청 후 프로세스 종료 확인 대기.

**변경 파일**: `server.sh`

---

### S1 — `tts_player.sh` 배열 파싱 개선 (LOW)

**문제**: `files=($(ls -1 ... | sort))` 패턴은 파일명에 공백이 있으면 깨진다.
epoch_ms 파일명은 공백 없이 안전하지만 bash best practice 위반.

**해결**: `mapfile -t files < <(find "$SPOOL" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) | sort)`로 교체.

**변경 파일**: `tts_server/tts_player.sh`

---

### S2 — `supertonic_start.sh` `sleep 1` race 제거 (LOW)

**문제**: `sleep 1; kill -0 $BGPID` 체크는 nohup 셸 생존 여부 확인이지 서버 기동 확인이 아니다.
하단의 30초 루프가 실제 헬스체크를 담당하므로 중복이고 오해 소지가 있다.

**해결**: `sleep 1` + 중간 `kill -0` 블록 제거. 30초 루프만 남긴다.

**변경 파일**: `tts_server/supertonic_start.sh`

---

## TypeScript 팀 항목

### L1 — `autoSpeak` 플래그 미적용 (MEDIUM)

**문제**: `SirenConfig.autoSpeak`를 `false`로 설정해도 stop hook은 항상 TTS를 실행한다.
`hooks/stop.sh`가 config를 읽지 않기 때문이다.

**해결**: `src/index.ts`의 `hook` CLI 분기에서 `config.autoSpeak` 체크 추가.
`autoSpeak: false`이면 `process.exit(0)` early return.

```typescript
if (process.argv[2] === "hook") {
  const text = await readStdin();
  if (!config.autoSpeak || text.length < config.minChars) {
    process.exit(0);
  }
  ...
}
```

**변경 파일**: `src/index.ts`  
**테스트**: `index` CLI 분기 통합 테스트 추가 (현재 없음).

---

### L2 — transcript content 배열 파싱 오류 (MEDIUM)

**문제**: `entry.content`가 tool_use 블록 배열일 때 `String(entry.content ?? "")`→ `"[object Object]"`.
transcript에서 실제 메시지 텍스트 대신 쓸모없는 문자열이 컨텍스트로 전달된다.

**해결**: content가 배열이면 각 블록에서 `text` 필드만 추출해 이어붙인다.
```typescript
function extractContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((b): b is { type: string; text: string } => typeof b?.text === "string")
      .map(b => b.text)
      .join(" ");
  }
  return "";
}
```

**변경 파일**: `src/skill-recommender.ts`  
**테스트**: 기존 `readRecentTranscripts` 테스트에 배열 content 케이스 추가.

---

### L3 — `hook-suggest` 컨텍스트 소스 정리 (MEDIUM)

**문제**: `process.argv[3] ?? readRecentTranscripts()` — `prompt-submit.sh`에서 raw 프롬프트를
argv[3]으로 넘기면 transcript 형식이 아닌 단일 문장이 컨텍스트로 사용된다.
LLM은 대화 흐름 없이 현재 입력만 보고 스킬을 추천한다.

**해결**: 항상 `readRecentTranscripts()`를 사용하고, 프롬프트를 추가 힌트로 포함시킨다.
```typescript
const transcripts = readRecentTranscripts();
const hint = process.argv[3] ? `\n[현재 입력]: ${process.argv[3]}` : "";
const context = transcripts + hint;
```

**변경 파일**: `src/index.ts`  
**테스트**: hook-suggest 분기 단위 테스트.

---

### Q1 — Dead config fields 제거 (LOW)

**문제**: `SirenConfig.ttsModel`·`language` 필드가 선언되어 있지만 어디서도 사용하지 않는다.

**해결**: `SirenConfig` 인터페이스와 `DEFAULTS` 객체에서 두 필드 삭제.

**변경 파일**: `src/config.ts`  
**테스트**: `config.test.ts` — loadConfig 반환 객체에 해당 필드가 없음 단언.

---

### Q2 — `getDefaultModel()` 불일치 통일 (LOW)

**문제**: `summarizer.ts`의 함수 시그니처 기본값이 `"gpt-5.4"` 하드코딩,
`skill-recommender.ts`만 `getDefaultModel()` 사용.

**해결**: `summarizer.ts`의 `model = "gpt-5.4"` 기본값을 `model = getDefaultModel()`로 교체.

**변경 파일**: `src/summarizer.ts`, `src/llm-client.ts` (import 추가)  
**테스트**: 기존 summarizer.test.ts 유지.

---

### Q3 — Spool 파일명 충돌 방지 (LOW)

**문제**: `Date.now()` ms 단위 타임스탬프로 파일명 생성.
동시 호출 시 같은 ms에 파일명이 충돌해 `renameSync`가 덮어씀.

**해결**: `${Date.now()}_${process.pid}_${Math.random().toString(36).slice(2,7)}`로 충분한 유일성 확보.

**변경 파일**: `src/player.ts`  
**테스트**: 기존 테스트 유지 (파일명 패턴 미검증).

---

### Q4 — `withTTSLock` 지수 백오프 (LOW)

**문제**: 300ms 고정 폴링 × 최대 83회. TTS Player와 달리 jitter/백오프 없음.

**해결**: 초기 100ms, 최대 1000ms로 지수 증가.
```typescript
let delay = 100;
await new Promise(r => setTimeout(r, delay));
delay = Math.min(delay * 1.5, 1000);
```

**변경 파일**: `src/player.ts`  
**테스트**: 기존 lock 테스트 유지.

---

### S3 — `sanitizeForSpeech` 문장 부호 보존 (LOW)

**문제**: `summarizer.ts`의 `sanitizeForSpeech()`가 `?`·`!` 등을 공백으로 치환.
자연스러운 억양 단서가 사라져 TTS 발음이 밋밋해질 수 있다.

**해결**: 정규식을 수정해 `?`·`!`·`.`·`,`를 허용 목록에 포함.
```typescript
.replace(/[^\p{L}\p{N}\s,.!?。]/gu, " ")
```

**변경 파일**: `src/summarizer.ts`  
**테스트**: `summarizer.test.ts` — `?`·`!`가 보존되는 케이스 추가.

---

## 완료 기준

| 기준 | 검증 방법 |
|---|---|
| 기존 71개 테스트 통과 | `npm test` |
| Python 테스트 통과 | `pytest tts_server/` |
| Supertonic 종료 동작 | `server.sh stop` 후 포트 7788 미점유 확인 |
| LaunchAgent 재시작 후 LLM 동작 | plist 환경변수 확인 |
| `autoSpeak: false` 작동 | `.siren.json`에서 비활성화 후 hook 미실행 확인 |

---

## 파일 변경 범위

| 팀 | 변경 파일 |
|---|---|
| Shell | `server.sh`, `tts_server/supertonic_stop.sh`, `tts_server/supertonic_start.sh`, `tts_server/tts_player.sh` |
| TypeScript | `src/index.ts`, `src/config.ts`, `src/player.ts`, `src/summarizer.ts`, `src/skill-recommender.ts`, `src/llm-client.ts` |
