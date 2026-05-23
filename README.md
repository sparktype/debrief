# Siren MCP — Claude Code 음성 응답 서버

Claude Code의 응답이 끝날 때 자동으로 요약해서 음성으로 읽어주는 MCP 서버.  
서브에이전트 타입에 따라 서로 다른 목소리를 배정하는 **다성 TTS**를 지원합니다.

## 특징

- **자동 요약 → 음성 재생** — Claude 응답 완료 시 LLM 요약 후 TTS 자동 실행
- **4단계 폴백 TTS** — Edge TTS → MLX TTS 서버 → MLX subprocess → macOS say
- **에이전트별 다성(多聲)** — 코드 리뷰어·플래너·빌더·탐색기 역할마다 다른 목소리
- **자기 소개 + 한 줄 보고** — 팀원 완료 시 `"리뷰어입니다. [25자 요약]"` 형식으로 발화
- **파일 스풀 큐** — 리더·팀원 오디오를 `/tmp/tts-spool/`에 순서대로 쌓고 단일 데몬이 직렬 재생
- **스킬 추천** — 대화 맥락 분석 → 적합한 Claude Code 스킬 자동 음성 안내
- **Apple Silicon 최적화** — MLX 프레임워크로 Metal GPU 활용

---

## 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│ Claude Code                                             │
│                                                         │
│  Stop 이벤트 ──→ hooks/stop.sh                          │
│  SubagentStop ──→ hooks/subagent-stop.sh                │
│  SessionStart ──→ hooks/session-start.sh                │
│  PromptSubmit ──→ hooks/prompt-submit.sh                │
└──────────────────────────┬──────────────────────────────┘
                           │ nohup node dist/index.js &
                           ▼
┌─────────────────────────────────────────────────────────┐
│ Node.js MCP 서버 (src/)                                 │
│                                                         │
│  hook 모드      ──→ extractSummary() → speakHook()      │
│                     → EdgeTTS MP3 → /tmp/tts-spool/     │
│  subagent-stop  ──→ getAgentLabel() → extractOneLiner() │
│                     → speakAgent() → Supertonic WAV     │
│                     → /tmp/tts-spool/                   │
│  hook-suggest   ──→ recommendSkill() → speak()          │
│  MCP 도구 모드  ──→ stdio transport (Claude Code 직접)   │
└──────────┬────────────────────────┬─────────────────────┘
           │                        │
           ▼                        │
┌──────────────────────────────┐    │ 파일 스풀
│ TTS Player 데몬               │ ◀──┘ /tmp/tts-spool/
│ (tts_server/tts_player.sh)   │ epoch_ms 순서대로 afplay
│ 단일 소비자 → 직렬 재생       │
└──────────────────────────────┘

┌──────────────────┐    ┌──────────────────────────────┐
│ Supertonic TTS   │    │ MLX TTS 상주 서버             │
│ (포트 7788)      │    │ (포트 7777)                   │
│ 에이전트별 다성  │    │ Qwen3-TTS-0.6B MLX 모델       │
│ M1/M2/M4/F1/F3  │    │ 단일 워커 스레드, 202 비동기   │
└──────────────────┘    └──────────────────────────────┘
```

### 리더(Stop hook) TTS 경로 (`speakHook()`)

```
1. EdgeTTS → ko-KR-HyunsuMultilingualNeural MP3 생성 (10초 타임아웃)
   ↓ 성공
   /tmp/tts-spool/<epoch_ms>.mp3 기록 → 즉시 반환
   ↓ EdgeTTS 실패
speakInner() 직접 재생 폴백 (Edge → MLX 서버 → subprocess → say)
```

### 서브에이전트 TTS 경로 (`speakAgent()`)

```
agentType → getAgentLabel() → "리뷰어" / "플래너" / "빌더" / "탐색기"
agentType → voice-map.json → Supertonic voice ID
extractOneLiner() → 25자 이내 한 줄 요약 → sanitizeForSpeech() 특수문자 제거
발화 텍스트: "${label}입니다. ${oneLiner}"

Supertonic 생존 확인 (localhost:7788/v1/health)
  ↓ 살아있음
WAV 생성 → /tmp/tts-spool/<epoch_ms>.wav 기록 → 즉시 반환
  ↓ 실패 또는 서버 없음
speakInner() 직접 재생 폴백

TTS Player 데몬이 스풀을 0.3초마다 폴링 → epoch_ms 오름차순 순차 재생
```

### MCP 도구 TTS 경로 (`speak()`)

```
1. Edge TTS      — Microsoft 온라인 TTS, 한영 혼합 최적
   ↓ 실패(10초 타임아웃)
2. MLX 서버      — 로컬 HTTP, localhost:7777, 즉시 202 반환
   ↓ 실패
3. MLX subprocess — tts-venv/bin/python3 -m mlx_audio.tts.generate
   ↓ 실패
4. macOS say     — 최후 폴백, 네트워크 불필요
```

---

## 요구사항

| 항목 | 버전 |
|------|------|
| macOS | 13 Ventura 이상 (Apple Silicon 권장) |
| Node.js | 18 이상 |
| Python | 3.11 이상 (tts-venv 전용) |
| MLX | Apple Silicon 필수 (Metal GPU) |

**환경변수** (`~/.zshenv` 또는 `~/.zprofile`):

```bash
export HUB_BASE_URL="https://your-llm-api/v3"  # OpenAI 호환 LLM API
export HUB_API_KEY="your-api-key"
export HUB_PROJECT_ID="your-project-id"        # X-Project-Id 헤더
```

LLM API가 없으면 요약 단계가 스킵되고 원문 마지막 3문장이 재생됩니다.

---

## 빠른 시작

```bash
# 1. 의존성 설치 + 모델 다운로드 (최초 1회, 약 1GB)
./setup-tts.sh

# 2. 빌드 + 서비스 등록 (Claude Code Stop hook + launchd)
./server.sh install

# 3. 상태 확인
./server.sh status
```

설치 후 Claude Code에서 답변이 완료될 때마다 자동으로 음성이 재생됩니다.

---

## 상세 설치

### 1단계 — Python 환경 및 TTS 모델 준비

```bash
./setup-tts.sh
```

이 스크립트가 수행하는 작업:
- `tts-venv/` 가상환경 생성
- `mlx-audio`, `edge-tts`, `supertonic[serve]`, `fastapi`, `uvicorn` 설치
- Qwen3-TTS 모델 다운로드 (`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`)
- launchd LaunchAgent 등록 (로그인 시 TTS 서버 자동 시작)

### 2단계 — Node.js 빌드 및 hook 등록

```bash
npm install
./server.sh install  # npm run build + hook 등록 + 서버 시작
```

### 3단계 — Supertonic 서버 시작 (에이전트 다성 TTS)

```bash
./tts_server/supertonic_start.sh
```

Supertonic이 없으면 서브에이전트 응답도 기본 voice로 재생됩니다.

### 수동 설치 (MCP 도구로만 사용)

Claude Code의 `claude_desktop_config.json`에 추가:

```json
{
  "mcpServers": {
    "siren": {
      "command": "node",
      "args": ["/path/to/summary-voice-mcp/dist/index.js"]
    }
  }
}
```

---

## 서버 관리

```bash
./server.sh start      # TTS 서버 시작
./server.sh stop       # 종료
./server.sh restart    # 빌드 + 재시작
./server.sh status     # 상태 확인
./server.sh logs [N]   # 마지막 N줄 로그 (기본 50)
./server.sh install    # hook + launchd 등록
./server.sh uninstall  # 완전 제거
```

---

## 설정

프로젝트 루트에 `.siren.json` 파일을 생성하면 기본값을 오버라이드할 수 있습니다.

```json
{
  "autoSpeak": true,
  "minChars": 50,
  "voice": "Sohee",
  "summaryModel": "gpt-4o",
  "ttsSpeed": 1.2,
  "ttsInstruct": "밝고 활기차게 말해주세요",
  "skillCooldownMinutes": 30
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | hook 모드 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `voice` | `"Sohee"` | MLX 스피커 ID 또는 macOS TTS 음성명 |
| `summaryModel` | `"gpt-5.4"` | LLM 요약에 사용할 모델 |
| `ttsSpeed` | `1.2` | 재생 속도 (`afplay -r`) |
| `ttsInstruct` | `"밝고 활기차게 말해주세요"` | Qwen3-TTS instruct 파라미터 |
| `skillCooldownMinutes` | `30` | 같은 스킬 재추천 억제 시간(분) |

런타임에 MCP `set_config` 도구로도 일부 설정 변경이 가능합니다.

---

## 지원 음성

### MLX 내장 스피커 (한국어 최적화)

`Sohee`, `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`

이 목록에 없는 이름은 `macOS say -v <name>`으로 자동 라우팅됩니다.

### Edge TTS 음성 (온라인)

`voice` 설정값에 관계없이 리더(Stop hook) 발화는 항상 `ko-KR-HyunsuMultilingualNeural`을 사용합니다.  
한영 혼합 발음에 최적화된 Microsoft 다국어 TTS 모델입니다.

### 에이전트별 Supertonic 음성 (다성 TTS)

서브에이전트 타입에 따라 자동으로 다른 목소리가 배정됩니다.

| 카테고리 | Voice ID | 해당 에이전트 타입 예시 |
|---------|---------|----------------------|
| reviewer | M2 | code-reviewer, security-reviewer, python-reviewer ... |
| planner | M1 | planner, architect, code-architect ... |
| builder | M4 | build-error-resolver, tdd-guide, gan-generator ... |
| explorer | F3 | Explore, code-explorer, general-purpose ... |
| default | F1 | 위 카테고리에 없는 모든 타입 |

에이전트 타입-카테고리 전체 매핑은 `voice-map.json`에서 편집할 수 있습니다.  
코드 변경 없이 JSON 파일만 수정하면 됩니다.

---

## MCP 도구

Claude Code와 직접 통합 시 사용 가능한 도구:

| 도구 | 설명 |
|------|------|
| `speak_text` | 텍스트를 그대로 음성 재생 |
| `summarize_and_speak` | LLM 요약 후 음성 재생 |
| `speak_last` | 마지막으로 재생한 텍스트 다시 재생 |
| `set_config` | 런타임 설정 변경 (`autoSpeak`, `minChars`, `ttsInstruct`) |
| `suggest_skill` | 현재 대화 맥락 분석 후 적합한 스킬 음성 추천 |

---

## 스킬 추천

`hooks/session-start.sh`와 `hooks/prompt-submit.sh`가 대화 맥락을 분석해  
적합한 Claude Code 스킬을 1개 음성으로 추천합니다.

- 같은 스킬은 30분(기본값) 동안 재추천하지 않음
- `suggest_skill` MCP 도구로 즉시 강제 추천 가능
- 추천 후보 목록: `skills-catalog.json` (편집 가능)

---

## 개발

### 빌드

```bash
npm run build     # TypeScript → dist/ 컴파일
npm run dev       # tsx로 src/index.ts 직접 실행 (빌드 없이)
```

### 테스트

```bash
npm test                                      # 전체 테스트
npm run test:watch                            # watch 모드
npx vitest run tests/player.test.ts           # 파일 단위
```

테스트 전략:
- `fetch`·`spawn`·`existsSync`를 mock해서 TTS 경로별로 분리 테스트
- `openai` 모듈 전체 mock — 실제 LLM 호출 없음
- `SIREN_DATA_DIR` 환경변수로 영속화 경로 격리
- `fs` mock에 `openSync`·`writeSync`·`closeSync`·`readFileSync` 포함 필수 — 누락 시 `withTTSLock`이 실제 잠금 파일을 생성해 테스트 간 데드락 발생

### 파일 구조

```
src/
  index.ts              # MCP 서버 진입점, CLI 분기
  config.ts             # .siren.json 로더, 기본값 관리
  player.ts             # TTS 폴백 체인 (Edge → HTTP → MLX → say) + withTTSLock
  summarizer.ts         # LLM 요약·한 줄 요약 + sanitizeForSpeech
  voice-router.ts       # agentType → Supertonic voice ID + 한국어 역할명
  llm-client.ts         # HMG Hub LLM 클라이언트 공통 모듈
  skill-recommender.ts  # transcript 분석 → 스킬 추천
  last-message-store.ts # 마지막 TTS 텍스트 영속화

tts_server/
  server.py             # FastAPI MLX TTS 상주 서버 (포트 7777)
  start.sh / stop.sh    # MLX 서버 시작/종료
  supertonic_start.sh   # Supertonic 서버 시작 (포트 7788)
  supertonic_stop.sh    # Supertonic 서버 종료
  tts_player.sh         # 스풀 소비자 데몬 — /tmp/tts-spool/ 순차 재생

hooks/
  stop.sh               # Claude Stop 이벤트 → hook 모드
  subagent-stop.sh      # SubagentStop 이벤트 → subagent-stop 모드
  session-start.sh      # SessionStart → 스킬 추천
  prompt-submit.sh      # UserPromptSubmit → 스킬 추천

voice-map.json          # 에이전트 카테고리-voice 매핑
skills-catalog.json     # 스킬 추천 후보 15개 목록
```

### 새 에이전트 타입 추가

`voice-map.json`의 `categories` 배열에 추가만 하면 됩니다. 코드 수정 불필요.

```json
{
  "categories": {
    "reviewer": ["code-reviewer", "my-new-reviewer"]
  }
}
```

새 카테고리를 추가할 경우 `src/voice-router.ts`의 `CATEGORY_LABELS`에 한국어명도 추가하세요.

```typescript
const CATEGORY_LABELS: Record<string, string> = {
  reviewer: "리뷰어",
  planner:  "플래너",
  builder:  "빌더",
  explorer: "탐색기",
  my_role:  "내역할명",  // 추가
};
```

### 팀 구성 시 모델 지정

HMG 사내 AI는 Opus 모델을 지원하지 않습니다. Agent 파라미터에 반드시 Sonnet을 지정하세요.

```typescript
Agent({
  subagent_type: "code-reviewer",
  model: "sonnet",   // claude-sonnet-4-6 — Opus 미지원
  ...
})
```

### 새 스킬 추천 후보 추가

`skills-catalog.json`에 항목 추가:

```json
[
  { "skill": "my-skill", "description": "이 스킬이 유용한 상황 설명" }
]
```

---

## 트러블슈팅

### TTS 서버가 시작되지 않음

```bash
./server.sh logs          # 로그 확인
./server.sh restart       # 강제 재시작
cat .tts_server.log       # 상세 로그
```

### macOS `say`만 재생됨 (MLX TTS가 작동 안 함)

```bash
# tts-venv가 없는 경우
./setup-tts.sh

# 서버가 내려간 경우
./server.sh start

# 헬스체크
curl http://localhost:7777/health
```

### 에이전트별 다른 목소리가 나오지 않음

```bash
# Supertonic 서버 상태 확인
curl http://localhost:7788/health

# Supertonic 시작
./tts_server/supertonic_start.sh
```

### TTS Player 데몬이 중지됨

리더·팀원 오디오가 스풀에 쌓이지만 재생되지 않으면 데몬이 죽은 것입니다.

```bash
./server.sh status        # TTS Player 상태 확인
./server.sh start         # 데몬 재시작
```

### Hook이 동작하지 않음

```bash
./server.sh status        # hook 등록 여부 확인
./server.sh install       # 재등록
```

### Edge TTS 실패 (HMG 사내망)

Edge TTS는 외부 네트워크가 필요합니다. 사내망 프록시에서 차단되면  
`.siren.json`에서 `voice`를 MLX 내장 스피커(`Sohee` 등)로 설정하면  
오프라인 MLX 경로만 사용합니다.

---

## 데이터 저장 경로

| 파일 | 설명 |
|------|------|
| `~/.local/share/summary-voice-mcp/last-message.txt` | 마지막 TTS 텍스트 |
| `~/.local/share/summary-voice-mcp/skill-cooldowns.json` | 스킬 추천 쿨다운 기록 |
| `.tts_server.log` | MLX TTS 서버 로그 |
| `SIREN_DATA_DIR` 환경변수로 경로 오버라이드 가능 | |
