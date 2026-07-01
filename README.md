# chorus

> Claude Code 응답을 자동으로 음성으로 읽어주는 hook 기반 TTS 시스템

Claude Code가 응답을 완료하면 자동으로 요약해서 읽어줍니다.  
멀티 에이전트 팀 작업 시 에이전트마다 다른 목소리로 발화합니다.

## 요구 사항

- macOS + Apple Silicon (M1/M2/M3/M4)
- [Claude Code CLI](https://claude.ai/code)
- Python 3.12+

## 설치

```bash
# 저장소 클론
git clone https://github.com/sparktype/chorus.git
cd chorus

# 초기 설치 (.venv 생성 + MLX 모델 다운로드)
./setup-tts.sh

# launchd + Stop hook 자동 등록
./server.sh install
```

설치 후 Claude Code를 재시작하면 자동으로 활성화됩니다.

## 기본 사용법

별도 설정 없이 바로 작동합니다.

- **Claude Code 응답 완료** → 자동 요약 후 음성 재생 (`🎙️ 요약 중...` → `▶️ 재생 중` 상태 표시)
- **서브에이전트 응답** → 에이전트 역할에 맞는 목소리 + earcon 전환음으로 발화
- **세션 시작 / 프롬프트 입력** → 상황에 맞는 스킬 음성 추천
- **`/listen` slash 명령** → Whisper STT 음성 입력 (선택 기능)

### 진단 및 제어 CLI

```bash
# 음성 테스트
python -m hook_voice voice test                      # 기본 목소리 TTS 테스트
python -m hook_voice voice test M2 "안녕하세요"       # 특정 목소리 지정

# 시스템 진단
python -m hook_voice doctor                          # 전체 헬스체크 + TTS 자가 테스트

# 재생 제어
python -m hook_voice control skip                    # 현재 트랙 건너뜀
python -m hook_voice control flush                   # 재생 큐 비우기
python -m hook_voice control pause                   # 일시정지
python -m hook_voice control resume                  # 재개

# API 직접 호출
curl -X POST localhost:7777/interrupt                # TTS 즉시 중단 (SIGTERM→SIGKILL)
curl localhost:7777/playback/status                  # 재생 상태 + 큐 깊이 확인
curl localhost:7777/health                           # 서버 상태 (model_loaded, queue_depth 포함)
```

## 설정

프로젝트 루트에 `.voice.json` 파일을 만들면 기본값을 오버라이드합니다 (`.voice-persona.json`도 폴백으로 지원).

```json
{
  "autoSpeak": true,
  "minChars": 50,
  "ttsSpeed": 1.1,
  "ttsInstruct": "밝고 활기차게 말해주세요",
  "summaryModel": "gemini-3.5-flash",
  "bridgeEnabled": false,
  "bridgeThresholdMs": 500,
  "resumeThreshold": 0.0,
  "stt": {
    "enabled": false,
    "model": "mlx-community/whisper-small-mlx",
    "language": "ko",
    "announce": true,
    "vadInterrupt": false
  }
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | hook 모드 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `ttsSpeed` | `1.1` | 재생 속도 (afplay -r) |
| `ttsInstruct` | `"밝고 활기차게 말해주세요"` | Supertonic 발화 스타일 |
| `summaryModel` | `"gemini-3.5-flash"` | 요약에 사용할 LLM 모델 |
| `speechRetouch` | `true` | LLM으로 마크다운 제거·IT 용어 발음 변환 |
| `skillCooldownMinutes` | `30` | 스킬 추천 재등장 최소 간격 |
| `supertonicPort` | `7777` | TTS 서버 포트 |
| `bridgeEnabled` | `false` | Stop hook 직후 브리지 음 재생 — 침묵 제거 opt-in |
| `bridgeThresholdMs` | `500` | 브리지 재생 최소 텍스트 길이 (글자 수) |
| `resumeThreshold` | `0.0` | interrupt 후 재개 임계값 (0.0 = 항상 포기, 0.85 = 85% 완료 시 재개) |
| `stt.enabled` | `false` | Whisper STT 활성화 |
| `stt.model` | `mlx-community/whisper-small-mlx` | Whisper 모델 |
| `stt.language` | `"ko"` | 인식 언어 |
| `stt.announce` | `true` | 녹음 시작/완료 TTS 안내 |
| `stt.vadInterrupt` | `false` | VAD 발화 감지 시 TTS 자동 중단 (macOS opt-in) |

## 에이전트 음성 (다성 TTS)

멀티 에이전트 팀 작업 시 에이전트 타입별로 다른 목소리를 사용합니다.  
`voice-map.json`을 편집해 매핑을 변경할 수 있습니다 — 코드 수정 없이 JSON만 바꾸면 됩니다.

| Voice ID | 이름 | 역할 | Instruct |
|----------|------|------|---------|
| F1 | 연아 | default (메인 응답) | 밝고 친절하게 |
| F2 | 마리 | tester | 또렷하고 정확하게 |
| F3 | 제인 | explorer | 밝고 호기심 있게 |
| F4 | 셰릴 | ops | 침착하고 명확하게 |
| F5 | 리사 | specialist | 전문적이고 자신감 있게 |
| M1 | 스티브 | planner | 차분하고 논리적으로 |
| M2 | 빌 | reviewer | 신중하게, 차분한 톤으로 |
| M3 | 일론 | optimizer | 군더더기 없이 빠르게 |
| M4 | 리누스 | builder | 빠르고 자신감 있게 |
| M5 | 팀 | guardian | 꼼꼼하고 신중하게 |

에이전트 전환 시 `earcon_switch.wav` (0.3초 880Hz 감쇠 톤)이 먼저 재생되어 목소리 교체를 청각적으로 알립니다.  
`voice-map.json`의 `earcon.enabled: false`로 비활성화할 수 있습니다.

## 스마트 발화 정책 (SmartTTS)

응답 타입에 따라 발화 모드와 우선순위를 자동 결정합니다.

| 응답 타입 | 발화 모드 | 우선순위 |
|-----------|-----------|---------|
| 에러·실패 키워드 포함 | 전체 낭독 | **HIGH** (즉시 선점) |
| 코드 블록 비중 40%+ | `[N줄 코드]와 함께 완료됐습니다` 축약 | NORMAL |
| 짧은 ack (`is_ack=True`) | earcon 음만 재생 | LOW |
| 일반 응답 | 전체 낭독 | NORMAL |

**우선순위 큐 정책:**
- **HIGH**: 기존 대기 파일 전부 제거 후 즉시 삽입
- **NORMAL**: 최대 3개 유지, 30초 TTL 초과 시 자동 만료
- **LOW**: 큐가 비었을 때만 삽입

## Whisper STT 음성 입력

마이크로 말하면 텍스트로 변환해 현재 포커스 위치에 자동 입력합니다 (Apple Silicon MLX 가속).

**활성화:**

```json
{ "stt": { "enabled": true } }
```

**사용법:**

| 방법 | 동작 |
|------|------|
| `/listen` slash 명령 | 녹음 시작/중지 토글 |
| Hammerspoon `Cmd+Shift+Space` | 동일 (단축키 방식) |
| `curl -X POST localhost:7777/stt/toggle` | 직접 API 호출 |

**VAD 자동 중단 (opt-in):** `stt.vadInterrupt: true` 설정 시 마이크 발화가 감지되면 현재 TTS 재생을 자동으로 중단합니다.

**Hammerspoon 설정** (`~/.hammerspoon/init.lua`):

```lua
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  hs.task.new("/usr/bin/curl", nil, {"-s", "-X", "POST", "http://localhost:7777/stt/toggle"}):start()
end)
```

## 서버 관리

```bash
./server.sh start     # 수동 시작
./server.sh stop      # 종료
./server.sh restart   # 재시작
./server.sh status    # 상태 확인
./server.sh logs [N]  # 마지막 N줄 로그 (기본 50)
./server.sh install   # launchd LaunchAgent + Stop hook 등록
./server.sh uninstall # 완전 제거
```

## 문제 해결

**소리가 전혀 안 날 때**
```bash
python -m hook_voice doctor          # 전체 진단
curl localhost:7777/health           # 서버 상태 확인
./server.sh status                   # TTS 서버 + hook 등록 여부
```

**음성이 중간에 잘릴 때**  
긴 요약이 잘리는 경우 `chunk_for_tts`가 자동으로 문장 단위로 분할합니다.  
문장 구분자(`.!?`) 없이 긴 텍스트가 오면 단일 청크로 처리됩니다.

**MLX 모델 로딩 실패**
```bash
tail -f .tts_server.log   # MLX 서버 로그 확인
uname -m                  # arm64 이어야 함
```

**Hook이 작동 안 할 때**
```bash
cat ~/.claude/settings.json | grep -A5 '"Stop"'   # hook 등록 확인
./server.sh install                                 # 재등록
```

## 개발자 가이드

<details>
<summary>아키텍처 및 개발 환경 설정</summary>

### 아키텍처

두 개의 주요 프로세스로 구성됩니다.

**hook_voice** (Python 패키지) — `hook_voice/`  
Claude Code hook에서 `python -m hook_voice <subcommand>`로 호출됩니다.

**TTS Supervisor** (Python, `tts_server/supervisor.py`) — launchd가 단일 프로세스로 관리
- uvicorn (포트 7777) — Supertonic MLX TTS + STT + 메트릭 + DLQ + 인터럽트 통합 서버
- TTS Player Loop — `/tmp/tts-spool/` 폴링 후 epoch_ms 오름차순 순차 재생

**실행 흐름 (Stop hook):**
```
Claude 응답 완료
  → bridge_enabled이면 bridge_thinking.wav 즉시 재생 (침묵 제거)
  → SpeechPolicy.decide(text) → 발화 모드·우선순위 결정
  → has_heavy_code(text)이면 코드 블록 축약 요약 생성
  → LLM extract_summary() → chunk_for_tts() → speak_hook_chunked()
  → enqueue_with_priority(priority) → /tmp/tts-spool/ → afplay 순차 재생
```

**실행 흐름 (SubagentStop hook):**
```
서브에이전트 응답 완료
  → earcon_switch.wav enqueue (전환 청각 큐)
  → f"{role} {name}입니다. {one_liner}" → speak_agent()
  → /tmp/tts-spool/ → afplay 재생
```

### 주요 파일

| 파일 | 역할 |
|------|------|
| `hook_voice/__main__.py` | CLI 진입점 |
| `hook_voice/config.py` | `.voice.json` 로더, 모든 설정 기본값 |
| `hook_voice/player.py` | speak_hook_chunked / speak_agent / enqueue_earcon |
| `hook_voice/summarizer.py` | LLM 요약 + 코드 축약 + TTS 청크 분할 |
| `hook_voice/voice_router.py` | agentType → voice ID·이름·instruct 변환 |
| `hook_voice/hook_handlers.py` | subcommand 구현 (voice test / doctor 포함) |
| `hook_voice/speech_listener.py` | Whisper STT + VAD interrupt |
| `hook_voice/delivery/priority_spool.py` | HIGH/NORMAL/LOW 우선순위 큐 + TTL |
| `hook_voice/event/policy.py` | SmartTTSRouter (SpeechPolicy) |
| `tts_server/server.py` | FastAPI TTS 서버 (포트 7777) |
| `tts_server/supervisor.py` | uvicorn + TTS Player 통합 supervisor |
| `assets/earcon_switch.wav` | 에이전트 전환 청각 큐 (0.3초) |
| `assets/bridge_thinking.wav` | 브리지 WAV — Stop hook 후 침묵 제거용 |

### 테스트

```bash
.venv/bin/pytest tests/ --tb=short -q              # hook_voice 테스트 (350+)
.venv/bin/pytest tts_server/test_server.py -v      # TTS 서버 테스트
.venv/bin/pytest tests/ tts_server/ -v             # 전체
```

### 환경변수

| 변수 | 용도 |
|------|------|
| `HUB_BASE_URL` | HMG 사내 LLM API 베이스 URL |
| `HUB_API_KEY` | LLM API 키 |
| `HUB_PROJECT_ID` | Hub 프로젝트 ID (X-Project-Id 헤더) |
| `HF_HUB_OFFLINE` | `1` 고정 — 런타임 HuggingFace 다운로드 차단 |
| `VOICE_PERSONA_DATA_DIR` | 영속화 데이터 경로 오버라이드 |

</details>

---

## 자동 학습·적응 레이어 (보류 기능)

> **현재 상태**: 설계 단계, 미구현. 개인정보 정책 확정 후 착수 예정.

### 무엇인가

사용자의 **실제 사용 패턴**을 로컬에서 수집·분석해, `.voice.json` 설정을 자동으로 제안하는 기능입니다.

예를 들어:
- "코드 블록 응답에서 자주 `skip` 하네 → `SmartTTS` 코드 임계값을 낮춰 권장"
- "오후 2시 이후엔 TTS를 거의 끄네 → `autoSpeak: false` 스케줄 제안"
- "builder 에이전트 발화 후 자주 중단하네 → builder에 LOW 우선순위 설정 권장"

### 왜 보류됐나

기능 자체는 구현 가능하지만 **데이터 수집 범위와 저장 정책**이 먼저 결정돼야 합니다.

**핵심 쟁점:**

1. **무엇을 수집하는가**  
   재생 완료율, 중단 횟수, 에이전트 타입별 패턴 — 이 데이터만 수집해도 간접적으로 작업 내용이 노출될 수 있습니다. "builder를 자주 쓰고 자주 끊었다"는 정보도 개인 작업 맥락입니다.

2. **어디에 저장하는가**  
   로컬(`~/.local/share/chorus/`)에만 저장하면 안전하지만, 여러 프로젝트 간 학습이 안 됩니다. 클라우드 동기화는 HMG 내부 정책 승인이 필요합니다.

3. **언제 적용하는가**  
   자동 튜닝은 예측 불가한 동작을 만들 수 있습니다. "어느 순간부터 목소리가 바뀌었는데 이유를 모른다"는 UX는 좋지 않습니다.

### 구현 시 설계 방향

합의된 원칙이 결정되면 아래 방향으로 구현 예정입니다.

```python
# 수집 대상 (익명 통계만)
- 재생 완료율 (완료 vs 중단)
- 에이전트 타입별 호출 빈도
- 발화 길이 분포
- 우선순위별 드롭율

# 적용 방식
- 자동 적용 없음 — 항상 사용자 확인 필요
- "최근 패턴 기반 권장 설정: {...}" 제안 형태
- 명시적 opt-in: `chorus suggest-config` 실행 시에만 생성

# 데이터 위치
- 로컬 only: ~/.local/share/chorus/usage_stats.json
- 프로젝트별 격리 (전역 학습 없음)
- `chorus privacy clear` 로 전체 삭제 가능
```

### 현재 대안

자동 학습 없이도 수동으로 동일한 효과를 낼 수 있습니다.

```bash
# 현재 설정 확인
python -m hook_voice config list

# 코드 응답이 너무 길게 읽힌다면 → SmartTTS 이미 적용 중
# 에러 응답을 놓쳤다면 → HIGH 우선순위로 자동 처리
# 특정 에이전트를 끊고 싶다면
python -m hook_voice control skip    # 현재 트랙 즉시 건너뜀
python -m hook_voice control flush   # 대기 중인 모든 발화 제거
```
