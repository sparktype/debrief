# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 팀 정보

**팀**: 개발생산성본부  
**오너**: 박상선 책임매니저  
**리포**: github.com/sparktype/summary-voice-mcp

작업 진행 시 Supertonic 서버(`./tts_server/supertonic_start.sh`)를 켜두면 에이전트별 다성 TTS가 활성화됩니다.  
에이전트 타입 → 목소리 매핑은 `voice-map.json`에서 편집하며, 코드 변경 없이 JSON만 수정하면 됩니다.

**팀 구성 시 모델**: 반드시 `claude-sonnet-4-6`(Sonnet 4.6)만 사용합니다.  
HMG 사내 AI에서 Opus 모델은 지원되지 않으며, Agent 파라미터 `model: "sonnet"`으로 지정합니다.

## 프로젝트 개요

Claude Code의 응답을 자동으로 음성으로 읽어주는 MCP 서버. 두 개의 독립적인 프로세스로 구성된다.

- **MCP 서버** (Node.js/TypeScript): Claude Code Stop hook에서 호출되거나 MCP tool로 사용
- **TTS 상주 서버** (Python/FastAPI, 포트 7777): MLX 모델을 메모리에 올려두고 요청을 처리

## 명령어

```bash
# 빌드
npm run build         # TypeScript → dist/ 컴파일

# 개발 (빌드 없이 실행)
npm run dev           # tsx로 src/index.ts 직접 실행

# 테스트
npm test              # vitest run (단일 실행)
npm run test:watch    # vitest watch 모드
npx vitest run tests/player.test.ts  # 파일 단위 실행

# TTS 서버 관리 (통합 스크립트)
./server.sh start     # 수동 시작
./server.sh stop      # 종료
./server.sh restart   # 빌드 + 재시작
./server.sh status    # 상태 확인 (빌드·TTS 서버·hook 등록 여부)
./server.sh logs [N]  # 마지막 N줄 로그 (기본 50)
./server.sh install   # Stop hook + launchd LaunchAgent 등록 (권장)
./server.sh uninstall # 완전 제거

# 초기 설치 (tts-venv 생성 + 모델 다운로드)
./setup-tts.sh
```

## 아키텍처

### 실행 흐름

```
Claude 응답 완료
  → Stop hook (hooks/stop.sh)
    → node dist/index.js hook  # stdin으로 텍스트 전달
      → extractSummary() (summarizer.ts)  # HMG LLM API → 규칙 기반 폴백
      → speakHook() (player.ts)
          ├─ EdgeTTS → ko-KR-HyunsuMultilingualNeural MP3 생성
          ├─ /tmp/tts-spool/<epoch_ms>.mp3 기록 → 즉시 반환
          └─ EdgeTTS 실패 시 speakInner() 직접 재생 폴백

서브에이전트 응답 완료
  → SubagentStop hook (hooks/subagent-stop.sh)
    → transcript.jsonl 역방향 파싱 → subagent_type 추출
    → node dist/index.js subagent-stop  # stdin + agentType 인수
      → resolveVoice(agentType) (voice-router.ts)  # voice-map.json → voice ID
      → getAgentLabel(agentType) → "리뷰어" / "플래너" / "빌더" / "탐색기"
      → extractOneLiner() (summarizer.ts)  # 25자 이내 한 줄 요약 + 특수문자 제거
      → "${label}입니다. ${oneLiner}" → speakAgent() (player.ts)
          ├─ Supertonic: localhost:7788/v1/health 확인 → WAV 생성
          ├─ /tmp/tts-spool/<epoch_ms>.wav 기록 → 즉시 반환
          └─ 실패 시 speakInner() 직접 재생 폴백

TTS Player 데몬 (tts_server/tts_player.sh)
  → /tmp/tts-spool/ 0.3초 폴링 → epoch_ms 오름차순 afplay 순차 재생

세션 시작 / 프롬프트 입력
  → SessionStart / UserPromptSubmit hook
    → node dist/index.js hook-suggest
      → readRecentTranscripts() → recommendSkill() (skill-recommender.ts)
      → speak() 로 스킬 음성 추천
```

### 파일별 역할

| 파일 | 역할 |
|------|------|
| `src/index.ts` | MCP 서버 진입점 + hook / subagent-stop / hook-suggest CLI 분기 |
| `src/config.ts` | `.siren.json` 로더, 기본값 관리 |
| `src/player.ts` | 4단계 폴백 TTS 재생 (Edge TTS → HTTP → MLX → say) |
| `src/summarizer.ts` | LLM 요약 (HMG Hub API) + 규칙 기반 폴백 |
| `src/voice-router.ts` | agentType → 카테고리 → Supertonic voice ID 변환 |
| `src/skill-recommender.ts` | transcript 분석 → LLM → 스킬 추천 + 쿨다운 관리 |
| `src/last-message-store.ts` | 마지막 TTS 텍스트 파일 영속화 (`speak_last` 지원) |
| `src/llm-client.ts` | HMG Hub LLM 클라이언트 공통 모듈 |
| `tts_server/server.py` | FastAPI TTS 서버 — 단일 워커 스레드로 MLX 모델 실행 |
| `tts_server/tts_player.sh` | 스풀 소비자 데몬 — `/tmp/tts-spool/` 순차 재생 |

### TTS 서버 설계 포인트

- MLX Metal GPU 스트림은 스레드를 옮기면 안 되기 때문에 모델 로드와 추론을 **동일한 단일 워커 스레드** 에서 처리
- `/speak` 요청은 즉시 202 반환, 큐 크기 1 (현재 재생 중이면 429)
- `afplay -r <speed>` 로 재생 속도 후처리 — Qwen3-TTS는 `speed!=1.0` 시 최적화 경로가 비활성화됨
- `lang_code=korean` 시 `_TECH_PHONETICS` 사전으로 영문 기술 용어 → 한국어 발음 치환
- **파일 스풀 직렬화**: hook(`speakHook`)·서브에이전트(`speakAgent`) 오디오는 `/tmp/tts-spool/`에 기록, TTS Player 데몬이 단일 소비자로 순차 재생 — 동시 발화 없음
- MCP 도구 `speak()`만 `/tmp/siren-tts.lock` 파일 잠금 사용 (직접 재생 경로)
- 서브에이전트 발화: `"${role}입니다. ${oneLiner}"` 형식, `sanitizeForSpeech()`로 특수문자·유니코드 기호 제거

### 설정 (`src/config.ts` 기본값)

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | hook 모드 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `voice` | `Sohee` | MLX 스피커 또는 macOS voice |
| `summaryModel` | `gpt-5.4` | HMG Hub LLM 모델 |
| `ttsSpeed` | `1.2` | afplay -r 배속 |
| `ttsInstruct` | `"밝고 활기차게 말해주세요"` | Qwen3-TTS instruct 파라미터 |

프로젝트 루트의 `.siren.json` 으로 개별 오버라이드 가능.

### 환경변수

| 변수 | 용도 |
|------|------|
| `HUB_BASE_URL` | HMG 사내 LLM API 베이스 URL |
| `HUB_API_KEY` | HMG Hub API 키 |
| `HUB_PROJECT_ID` | Hub 프로젝트 ID (X-Project-Id 헤더) |
| `HF_HUB_OFFLINE` | `1` 고정 — 런타임 HuggingFace 다운로드 차단 |
| `SIREN_DATA_DIR` | 영속화 데이터 경로 오버라이드 (기본: `~/.local/share/summary-voice-mcp`) |
| `SIREN_OFFLINE` | `1` 설정 시 Edge TTS 건너뛰고 MLX 서버부터 시도 |

### MLX 내장 스피커

`Sohee`, `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`

이 목록에 없는 voice는 macOS `say -v <voice>` 로 라우팅됨.

## MCP 도구

| 도구 | 설명 |
|------|------|
| `speak_text` | 텍스트를 그대로 음성 재생 |
| `summarize_and_speak` | LLM 요약 후 음성 재생 |
| `speak_last` | 마지막으로 재생한 텍스트 다시 재생 |
| `set_config` | 런타임 설정 변경 (`autoSpeak`, `minChars`, `ttsInstruct`) |
| `suggest_skill` | 대화 맥락 분석 후 적합한 스킬 음성 추천 (쿨다운 무시) |

## Claude Code 연동 (`.claude/settings.json`)

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "<프로젝트>/hooks/stop.sh", "timeout": 15}]
    }]
  }
}
```

`./server.sh install` 이 이 설정을 자동 등록.

## 테스트 전략

- HTTP 서버 경로 / MLX subprocess 경로 / macOS say 경로를 `fetch`·`spawn`·`existsSync` mock으로 분리 테스트
- `openai` 모듈 전체를 mock — 실제 LLM 호출 없음
- `config.test.ts`: 파일 존재/파싱 실패/병합 케이스를 임시 파일(`/tmp/test-siren.json`)로 테스트
- `player.test.ts`: `fs` mock에 `openSync`·`writeSync`·`closeSync`·`readFileSync` 포함 필수 — 미포함 시 `withTTSLock`이 실제 파일을 생성해 테스트 간 데드락 발생
