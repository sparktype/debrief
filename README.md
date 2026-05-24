# voice-persona

> Claude Code 응답을 자동으로 음성으로 읽어주는 MCP 서버

Claude Code가 응답을 완료하면 자동으로 요약해서 읽어줍니다.
멀티 에이전트 팀 작업 시 에이전트마다 다른 목소리로 발화합니다.

## 요구 사항

- macOS + Apple Silicon (M1/M2/M3/M4)
- [Claude Code CLI](https://claude.ai/code)
- Python 3.11+

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/sparktype/voice-persona/main/install.sh | bash
```

설치 시간: 약 1~3분 (MLX 모델 다운로드 제외)

## 기본 사용법

설치 후 Claude Code를 재시작하면 자동으로 활성화됩니다.
별도 설정 없이 바로 작동합니다.

- Claude Code 응답 완료 → 자동 요약 후 음성 재생
- 서브에이전트 응답 → 에이전트 역할에 맞는 목소리로 발화
- 세션 시작 / 프롬프트 입력 → 상황에 맞는 스킬 음성 추천

## 설정

프로젝트 루트에 `.voice-persona.json` 파일을 만들면 기본값을 오버라이드할 수 있습니다.

```json
{
  "autoSpeak": true,
  "minChars": 50,
  "voice": "Sohee",
  "ttsSpeed": 1.2,
  "ttsInstruct": "밝고 활기차게 말해주세요"
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | hook 모드 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `voice` | `"Sohee"` | 기본 목소리 |
| `ttsSpeed` | `1.2` | 재생 속도 (afplay -r) |
| `ttsInstruct` | `"밝고 활기차게 말해주세요"` | Qwen3-TTS 발화 스타일 |
| `skillCooldownMinutes` | `30` | 스킬 추천 재등장 최소 간격 |
| `summaryModel` | `"gpt-5.4"` | 요약에 사용할 LLM 모델 |
| `supertonicPort` | `7788` | Supertonic TTS 서버 포트 |

## 내장 목소리

MLX 모델을 사용하는 내장 목소리:

`Sohee` `Vivian` `Serena` `Uncle_Fu` `Dylan` `Eric` `Ryan` `Aiden` `Ono_Anna`

이 목록에 없는 이름은 macOS `say -v <voice>` 로 라우팅됩니다.

## MCP 도구

Claude Code 내에서 직접 호출할 수 있는 도구:

| 도구 | 설명 |
|------|------|
| `speak_text` | 텍스트를 그대로 음성 재생 |
| `summarize_and_speak` | LLM 요약 후 음성 재생 |
| `speak_last` | 마지막으로 재생한 텍스트 다시 재생 |
| `set_config` | 런타임 설정 변경 (`autoSpeak`, `minChars`, `ttsInstruct`) |
| `suggest_skill` | 대화 맥락 분석 후 스킬 음성 추천 |

## 에이전트 음성 (다성 TTS)

멀티 에이전트 팀 작업 시 에이전트 타입별로 다른 목소리를 사용합니다.
`voice-map.json`을 편집해 매핑을 변경할 수 있습니다 — 코드 수정 없이 JSON만 바꾸면 됩니다.

Supertonic TTS 서버는 supervisor가 자동으로 기동합니다 — `./server.sh status`로 확인할 수 있습니다.

## 문제 해결

**소리가 전혀 안 날 때**
```bash
# TTS 플레이어 데몬 상태 확인
launchctl list | grep voice-persona

# 서버 상태 확인
./server.sh status
```

**"Edge TTS timeout" 오류**
- 인터넷 연결 확인 (Edge TTS는 Microsoft 서버 사용)
- 오프라인 환경: `VOICE_PERSONA_OFFLINE=1` 환경변수 설정 시 MLX 서버 우선 사용

**MLX 모델 로딩 실패**
- MLX 서버 로그 확인: `tail -f ~/.local/share/voice-persona/.tts_server.log`
- Apple Silicon 확인: `uname -m` → `arm64` 이어야 함

**Hook이 작동 안 할 때**
```bash
# hook 등록 확인
cat ~/.claude/settings.json | grep -A5 '"Stop"'

# 재등록
bash ~/.local/share/voice-persona/install.sh
```

## 제거

```bash
bash ~/.local/share/voice-persona/uninstall.sh
```

## 개발자 가이드

<details>
<summary>아키텍처 및 개발 환경 설정</summary>

### 아키텍처

두 개의 주요 프로세스로 구성됩니다.

**hook_voice** (Python 패키지) — `hook_voice/`
Claude Code hook에서 `python -m hook_voice <subcommand>`로 호출됩니다.
Edge TTS → HTTP (MLX) → macOS say 순으로 폴백합니다.

**TTS Supervisor** (Python, `tts_server/supervisor.py`) — launchd가 단일 프로세스로 관리
- uvicorn (포트 7777) — MLX Metal GPU TTS
- supertonic (포트 7788) — 다성 TTS
- TTS Player Loop — `/tmp/tts-spool/` 폴링 후 epoch_ms 오름차순 순차 재생

### 테스트

```bash
.venv/bin/pytest tests/ -v                       # hook_voice 테스트
.venv/bin/pytest tts_server/ -v                  # TTS 서버 테스트
.venv/bin/pytest tests/ tts_server/ -v           # 전체
```

### 서버 관리

```bash
./server.sh start    # 수동 시작
./server.sh stop     # 종료
./server.sh status   # 상태 확인
./server.sh logs     # 로그 확인
```

### 환경변수

| 변수 | 용도 |
|------|------|
| `VOICE_PERSONA_DATA_DIR` | 영속화 데이터 경로 오버라이드 |
| `VOICE_PERSONA_OFFLINE` | `1` 설정 시 Edge TTS 건너뜀 |
| `VOICE_PERSONA_VENV_PYTHON` | Python venv 경로 오버라이드 |
| `HUB_BASE_URL` | LLM API 베이스 URL (선택) |
| `HUB_API_KEY` | LLM API 키 (선택, 미설정 시 요약 스킵) |

### 파일 역할

| 파일 | 역할 |
|------|------|
| `hook_voice/__main__.py` | `python -m hook_voice <subcommand>` 진입점 |
| `hook_voice/config.py` | `.voice-persona.json` 로더 |
| `hook_voice/player.py` | EdgeTTS spool + TTS 재생 폴백 체인 |
| `hook_voice/summarizer.py` | LLM 요약 + 규칙 기반 폴백 |
| `hook_voice/voice_router.py` | agentType → voice ID 변환 |
| `hook_voice/hook_handlers.py` | 각 subcommand 구현 함수 |
| `tts_server/server.py` | FastAPI MLX TTS 서버 |
| `tts_server/supervisor.py` | uvicorn·supertonic·TTS Player 통합 supervisor |

</details>
