# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 팀 정보

**팀**: 개발생산성본부  
**오너**: 박상선 책임매니저  
**리포**: github.com/sparktype/summary-voice-mcp

TTS Supervisor(`./server.sh status`)가 실행 중이면 Supertonic이 자동으로 켜져 에이전트별 다성 TTS가 활성화됩니다.  
에이전트 타입 → 목소리 매핑은 `voice-map.json`에서 편집하며, 코드 변경 없이 JSON만 수정하면 됩니다.

**팀 구성 시 모델**: 반드시 `claude-sonnet-4-6`(Sonnet 4.6)만 사용합니다.  
HMG 사내 AI에서 Opus 모델은 지원되지 않으며, Agent 파라미터 `model: "sonnet"`으로 지정합니다.

## 프로젝트 개요

Claude Code의 응답을 자동으로 음성으로 읽어주는 hook 기반 시스템. 두 개의 주요 프로세스로 구성된다.

- **hook_voice** (Python 패키지): `python -m hook_voice <subcommand>` — Claude Code hook에서 호출
- **TTS Supervisor** (`tts_server/supervisor.py`): launchd가 단일 프로세스로 관리 — uvicorn(포트 7777)·supertonic(포트 7788)·TTS Player 루프를 포함

## 명령어

```bash
# 테스트
tts-venv/bin/pytest tests/ -v                        # hook_voice 테스트
tts-venv/bin/pytest tts_server/test_server.py -v    # TTS 서버 테스트
tts-venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v  # 전체

# TTS 서버 관리 (통합 스크립트)
./server.sh start     # 수동 시작
./server.sh stop      # 종료
./server.sh restart   # 재시작
./server.sh status    # 상태 확인 (TTS 서버·hook 등록 여부)
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
    → python -m hook_voice hook
      → extract_summary() (hook_voice/summarizer.py)  # HMG LLM API → 규칙 기반 폴백
      → speak_hook() (hook_voice/player.py)
          ├─ EdgeTTS → ko-KR-HyunsuMultilingualNeural MP3 생성
          ├─ /tmp/tts-spool/<ts>_<rand>.mp3 기록 → 즉시 반환
          └─ EdgeTTS 실패 시 HTTP(7777) → subprocess 폴백

서브에이전트 응답 완료
  → SubagentStop hook (hooks/subagent-stop.sh)
    → python -m hook_voice subagent-stop [agentType]
      → resolve_voice(agentType) (hook_voice/voice_router.py)  # voice-map.json → voice ID
      → get_agent_label(agentType) → "리뷰어" / "플래너" / "빌더" / "탐색기"
      → extract_one_liner() (hook_voice/summarizer.py)  # 25자 이내 한 줄 요약 + 특수문자 제거
      → f"{label}입니다. {one_liner}" → speak_agent() (hook_voice/player.py)
          ├─ Supertonic: localhost:7788/v1/health 확인 → WAV 생성
          ├─ /tmp/tts-spool/<ts>_<rand>.wav 기록 → 즉시 반환
          └─ 실패 시 HTTP(7777) → subprocess 폴백

TTS Player Loop (supervisor.py 내 asyncio Task)
  → /tmp/tts-spool/ 폴링 → ts 오름차순 afplay 순차 재생

세션 시작 / 프롬프트 입력
  → SessionStart / UserPromptSubmit hook
    → python -m hook_voice hook-suggest
      → read_recent_transcripts() → recommend_skill() (hook_voice/skill_recommender.py)
      → speak_hook() 로 스킬 음성 추천
```

### 파일별 역할

| 파일 | 역할 |
|------|------|
| `hook_voice/__main__.py` | `python -m hook_voice <subcommand>` 진입점 |
| `hook_voice/config.py` | `.voice-persona.json` 로더, 기본값 관리 |
| `hook_voice/llm_client.py` | HMG Hub LLM 클라이언트 (httpx AsyncClient) |
| `hook_voice/last_message.py` | 마지막 TTS 텍스트 파일 영속화 |
| `hook_voice/summarizer.py` | LLM 요약 + 규칙 기반 폴백 |
| `hook_voice/voice_router.py` | agentType → 카테고리 → Supertonic voice ID 변환 |
| `hook_voice/skill_recommender.py` | transcript 분석 → LLM → 스킬 추천 + 쿨다운 관리 |
| `hook_voice/player.py` | EdgeTTS spool enqueue, speak_hook/speak_agent + 폴백 |
| `hook_voice/hook_handlers.py` | 각 subcommand 구현 함수 |
| `tts_server/server.py` | FastAPI TTS 서버 — 단일 워커 스레드로 MLX 모델 실행 |
| `tts_server/supervisor.py` | uvicorn·supertonic·TTS Player 통합 supervisor |

### TTS 서버 설계 포인트

- MLX Metal GPU 스트림은 스레드를 옮기면 안 되기 때문에 모델 로드와 추론을 **동일한 단일 워커 스레드** 에서 처리
- `/speak` 요청은 즉시 202 반환, 큐 크기 1 (현재 재생 중이면 429)
- `afplay -r <speed>` 로 재생 속도 후처리 — Qwen3-TTS는 `speed!=1.0` 시 최적화 경로가 비활성화됨
- `lang_code=korean` 시 `_TECH_PHONETICS` 사전으로 영문 기술 용어 → 한국어 발음 치환
- **파일 스풀 직렬화**: hook·서브에이전트 오디오는 `/tmp/tts-spool/`에 기록, TTS Player 데몬이 단일 소비자로 순차 재생 — 동시 발화 없음
- 서브에이전트 발화: `f"{role}입니다. {one_liner}"` 형식, `sanitize_for_speech()`로 특수문자·유니코드 기호 제거
- **HMG SSL 프록시 우회**: `edge_tts.communicate._SSL_CTX`를 `CERT_NONE` 컨텍스트로 모듈 임포트 시점에 교체

### 설정 (`hook_voice/config.py` 기본값)

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | hook 모드 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `voice` | `Sohee` | MLX 스피커 또는 macOS voice |
| `summaryModel` | `gpt-5.4` | HMG Hub LLM 모델 |
| `ttsSpeed` | `1.2` | afplay -r 배속 |
| `ttsInstruct` | `"밝고 활기차게 말해주세요"` | Qwen3-TTS instruct 파라미터 |

프로젝트 루트의 `.voice-persona.json` 으로 개별 오버라이드 가능.

### 환경변수

| 변수 | 용도 |
|------|------|
| `HUB_BASE_URL` | HMG 사내 LLM API 베이스 URL |
| `HUB_API_KEY` | HMG Hub API 키 |
| `HUB_PROJECT_ID` | Hub 프로젝트 ID (X-Project-Id 헤더) |
| `HF_HUB_OFFLINE` | `1` 고정 — 런타임 HuggingFace 다운로드 차단 |
| `VOICE_PERSONA_DATA_DIR` | 영속화 데이터 경로 오버라이드 (기본: `~/.local/share/voice-persona`) |
| `VOICE_PERSONA_OFFLINE` | `1` 설정 시 Edge TTS 건너뛰고 MLX 서버부터 시도 |

### MLX 내장 스피커

`Sohee`, `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`

이 목록에 없는 voice는 macOS `say -v <voice>` 로 라우팅됨.

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

- `pytest` + `pytest-asyncio` (`asyncio_mode = auto`)로 async 함수 테스트
- `httpx.AsyncMock` / `unittest.mock.AsyncMock`으로 LLM·TTS HTTP 호출 mock
- `edge_tts.Communicate.save()`는 `AsyncMock`으로 대체
- 분류 함수(`classify_pre_tool_bash`, `classify_post_tool_bash`)는 순수 함수 — mock 불필요
- 파일 I/O 테스트: `tmp_path` fixture (pytest 내장) 활용
