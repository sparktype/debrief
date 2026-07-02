# chorus — 개발자 가이드

chorus의 아키텍처, 구현 결정, 개발 환경 설정을 다룹니다.  
사용자 가이드는 [README.md](README.md)를 참고하세요.

---

## 목차

1. [아키텍처 개요](#아키텍처-개요)
2. [파일 구조](#파일-구조)
3. [실행 흐름](#실행-흐름)
4. [핵심 모듈 설명](#핵심-모듈-설명)
5. [API 레퍼런스](#api-레퍼런스)
6. [설정 레퍼런스](#설정-레퍼런스)
7. [테스트](#테스트)
8. [환경변수](#환경변수)
9. [변경 이력](#변경-이력)

---

## 아키텍처 개요

두 개의 주요 프로세스로 구성됩니다.

```
Claude Code
  │
  ├─ Stop hook ──────────────────────────────────────► hook_voice 패키지
  │   (hooks/stop.sh)                                  (python -m hook_voice hook)
  │
  └─ SubagentStop hook ─────────────────────────────► hook_voice 패키지
      (hooks/subagent-stop.sh)                         (python -m hook_voice subagent-stop)
                                                              │
                                                              ▼
                                               TTS Supervisor (포트 7777)
                                               ├─ uvicorn + FastAPI (server.py)
                                               │    /v1/tts  /interrupt  /health
                                               │    /stt/toggle  /playback/status
                                               └─ TTS Player Loop (supervisor.py)
                                                    /tmp/tts-spool/ 폴링 → afplay
```

**hook_voice** (Python 패키지)
- Claude Code hook에서 `python -m hook_voice <subcommand>`로 호출
- LLM 요약, TTS 요청, 통계 수집, CLI 명령 처리

**TTS Supervisor** (`tts_server/supervisor.py`)
- launchd가 단일 프로세스로 관리
- uvicorn(포트 7777) + TTS Player Loop 통합

---

## 파일 구조

```
chorus/
├── hook_voice/
│   ├── __main__.py              # CLI 진입점 — subcommand 라우터
│   ├── config.py                # .voice.json 로더 + Config dataclass
│   ├── hook_handlers.py         # 각 subcommand 구현 함수
│   ├── player.py                # TTS spool enqueue — speak_hook_chunked / speak_agent
│   ├── summarizer.py            # LLM 요약 + 코드 축약 + TTS 청크 분할
│   ├── voice_router.py          # agentType → voice ID·이름·instruct 변환
│   ├── llm_client.py            # HMG Hub LLM 클라이언트 (httpx AsyncClient)
│   ├── last_message.py          # 마지막 TTS 텍스트 영속화
│   ├── skill_recommender.py     # transcript 분석 → 스킬 추천
│   ├── transcript_parser.py     # Claude transcript JSONL 파서
│   ├── speech_listener.py       # Whisper STT + VAD interrupt
│   │
│   ├── delivery/
│   │   ├── priority_spool.py    # HIGH/NORMAL/LOW 우선순위 큐 + 30초 TTL
│   │   └── earcon.py            # earcon WAV enqueue 헬퍼
│   │
│   ├── event/
│   │   ├── policy.py            # SmartTTSRouter (SpeechPolicy) + PolicyDecisionEngine
│   │   ├── canonical.py         # CanonicalEvent dataclass
│   │   ├── queue.py             # 이벤트 큐
│   │   └── router.py            # 이벤트 라우터
│   │
│   ├── learning/
│   │   ├── stats_store.py       # TTS 사용 통계 JSONL 저장·조회·삭제
│   │   └── advisor.py           # 통계 분석 → 설정 권장안 생성
│   │
│   ├── observability/
│   │   ├── circuit_breaker.py   # 서킷 브레이커
│   │   ├── context.py           # 요청 컨텍스트 (correlation_id)
│   │   ├── dlq.py               # Dead Letter Queue
│   │   ├── metrics.py           # Prometheus 메트릭
│   │   ├── otel.py              # OpenTelemetry
│   │   └── structured_log.py    # 구조화 로그
│   │
│   ├── speech/
│   │   ├── pipeline.py          # TTS 전용 텍스트 정제 파이프라인
│   │   └── pronunciation_db.py  # 발음 변환 사전
│   │
│   └── adapters/
│       ├── base.py
│       ├── coding_agent.py
│       └── grafana.py
│
├── tts_server/
│   ├── server.py                # FastAPI 서버 (포트 7777)
│   └── supervisor.py            # uvicorn + TTS Player 통합 supervisor
│
├── hooks/
│   ├── stop.sh                  # Claude Stop hook
│   ├── subagent-stop.sh         # SubagentStop hook
│   └── listen.sh                # /listen slash 명령
│
├── assets/
│   ├── earcon_switch.wav        # 에이전트 전환 청각 큐 (0.3초 880Hz 감쇠 톤)
│   └── bridge_thinking.wav      # 브리지 WAV — 침묵 제거용 (0.5초)
│
├── tests/                       # pytest 단위 테스트 (401+ passed)
├── voice-map.json               # 에이전트 → 목소리 매핑
├── server.sh                    # TTS 서버 관리 스크립트
└── setup-tts.sh                 # 초기 설치 스크립트
```

---

## 실행 흐름

### Stop hook (메인 응답)

```
Claude 응답 완료
  → hooks/stop.sh
    → python -m hook_voice hook
      → [선택] bridge_thinking.wav 즉시 enqueue (bridgeEnabled=true, 침묵 제거)
      → SpeechPolicy.decide(text)
          ├─ is_error → HIGH priority, full mode
          ├─ code 40%+ → NORMAL, summary_only
          ├─ is_ack → LOW, earcon_only (earcon_switch.wav enqueue)
          └─ 기타 → NORMAL, full
      → has_heavy_code(text)?
          ├─ yes → summarize_with_code_hint()  ← LLM 호출 없음
          └─ no  → extract_summary() (LLM)
      → [선택] speech_retouch pipeline (마크다운 제거, IT 용어 발음 변환)
      → chunk_for_tts(summary, max_chars=80)  ← 문장 단위 분할
      → speak_hook_chunked()
          → 청크별 enqueue_with_priority(priority)
              ├─ HIGH → 기존 파일 전부 제거 후 삽입
              ├─ NORMAL → max 3개, 30초 TTL
              └─ LOW → 큐 비어야 삽입
      → /tmp/tts-spool/<ts>_<rand>_<speed>.wav 생성
      → [선택] _record_stat(agent_type="default", ...) (usageTracking=true)

TTS Player Loop (supervisor.py)
  → /tmp/tts-spool/ 폴링 (ts 오름차순)
  → afplay -r <speed> <file>
  → 재생 완료 → 파일 삭제
```

### SubagentStop hook

```
서브에이전트 응답 완료
  → hooks/subagent-stop.sh
    → python -m hook_voice subagent-stop [agentType]
      → voice_router.py에서 agentType → voice·이름·instruct·label 결정
      → extract_one_liner_with_tag() (LLM 한 줄 요약 + 감정 태그)
      → [earcon.enabled=true] earcon_switch.wav enqueue (전환 청각 큐)
      → speak_text = f"{label} {voice_name}입니다. {tag}{one_liner}"
      → speak_agent()
          → POST localhost:7777/v1/tts (voice별 파라미터)
          → WAV bytes → /tmp/tts-spool/ enqueue
      → _record_stat(agent_type=agentType, ...) (usageTracking=true)
```

### TTS 서버 엔드포인트

```
POST /v1/tts          텍스트 → WAV 바이트 생성 (supertonic-mlx)
GET  /v1/health       모델 로드 상태 확인
GET  /health          서버 헬스 (model_loaded, queue_depth, stt_enabled)
POST /interrupt       현재 afplay SIGTERM → 0.3초 → SIGKILL
GET  /playback/status 재생 상태 + 큐 깊이
POST /stt/toggle      STT 녹음 시작/중지
GET  /stt/status      STT 상태
GET  /metrics         Prometheus 메트릭
GET  /metrics/json    메트릭 + circuit_breaker + dlq_pending
POST /admin/dlq/replay DLQ 재시도
```

---

## 핵심 모듈 설명

### `hook_voice/summarizer.py`

TTS에 최적화된 텍스트 처리 파이프라인.

| 함수 | 역할 |
|------|------|
| `extract_summary(text, model)` | LLM으로 1~3문장 요약 |
| `has_heavy_code(text) -> bool` | 코드 블록 비중 40% 초과 여부 |
| `summarize_with_code_hint(text) -> str` | 코드 비중 높으면 `"[N줄 코드]와 함께 완료됐습니다"` |
| `chunk_for_tts(text, max_chars=80) -> list[str]` | 문장 경계 기준 TTS 청크 분할 |
| `sanitize_for_speech(text) -> str` | 특수문자 제거 + Expression Tag 보존 |
| `retouch_for_speech(text, model)` | LLM 마크다운 제거·IT 용어 발음 변환 |

**Expression Tags (Supertonic 감정 태그):**  
`<breath>` `<laugh>` `<sigh>` `<clear_throat>` `<hmm>` `<cough>` `<sniff>` `<gasp>` `<yawn>` `<cry>`

---

### `hook_voice/delivery/priority_spool.py`

```python
enqueue_with_priority(
    audio_path: Path,
    speed: float,
    priority: str = "NORMAL",  # "HIGH" | "NORMAL" | "LOW"
    spool_dir: Path | None = None,
) -> None
```

| priority | 동작 |
|----------|------|
| HIGH | 기존 NORMAL/LOW 파일 전부 제거 후 삽입 |
| NORMAL | 최대 3개 유지, 30초 TTL 초과 시 만료 |
| LOW | 큐가 비어있을 때만 삽입 |

---

### `hook_voice/event/policy.py`

**SmartTTSRouter:**

```python
@dataclass
class SpeechDecision:
    mode: str      # "full" | "summary_only" | "earcon_only" | "skip"
    priority: str  # "HIGH" | "NORMAL" | "LOW"

SpeechPolicy.decide(text, is_error=False, is_ack=False) -> SpeechDecision
```

**PolicyDecisionEngine:** 이벤트 중복 제거(TTL 기반), 우선순위 필터, TTL 만료 처리.

---

### `hook_voice/learning/`

**stats_store.py:**

```python
record_playback(agent_type, mode, priority, completed, duration_secs) -> None
load_stats(limit=500) -> list[dict]
clear_stats() -> int  # 삭제된 항목 수
stats_file_path() -> Path  # ~/.local/share/chorus/usage_stats.jsonl
```

**advisor.py:**

```python
@dataclass
class Suggestion:
    key: str        # 예: "ttsSpeed", "builder_priority"
    current: Any    # 현재 값 (None이면 미확인)
    recommended: Any
    reason: str     # 경어체 설명

analyze(stats: list[dict], current_speed: float | None = None) -> list[Suggestion]
```

**분석 규칙 3가지:**
1. 전체 중단율 > 50% → `ttsSpeed: 0.95` 권장
2. HIGH 우선순위 발화 비중 > 30% → SmartTTS 동작 중임을 안내 (`error_priority_info`)
3. 특정 에이전트 완료율 < 60% (최소 5건) → `{agent}_priority: LOW` 권장

---

### `tts_server/server.py`

**주요 설계:**
- `ThreadPoolExecutor(max_workers=1)` — MLX Metal GPU 스레드 친화성 유지
- SIGTERM 먼저, 0.3초 후 미종료 시 SIGKILL
- `SPOOL_DIR_SERVER = Path("/tmp/tts-spool")`
- 한국어 기술 용어 발음 치환: `_TECH_PHONETICS` 사전 + `_preprocess()`

---

### `hook_voice/speech_listener.py`

**VAD (Voice Activity Detection):**
- `_VAD_RMS_THRESHOLD = 0.01` — 마이크 입력 RMS 임계값
- `_vad_fired` 플래그 — 연속 기동 억제 (새 녹음 세션마다 리셋)
- 발화 감지 시 `POST localhost:7777/interrupt` 자동 호출

---

## API 레퍼런스

### `POST /v1/tts`

```json
{
  "text": "안녕하세요",
  "lang": "ko",
  "voice": "F1",
  "steps": 8,
  "speed": 1.05,
  "response_format": "wav"
}
```

응답: `audio/wav` 바이트

### `POST /interrupt`

```json
{ "force": false }
```

응답:
```json
{
  "status": "interrupted",  // "not_playing" | "interrupted" | "error"
  "pid": 12345,
  "resume_threshold": 0.0
}
```

### `GET /health`

```json
{
  "status": "ok",
  "model_loaded": true,
  "queue_depth": 2,
  "stt_enabled": false
}
```

### `GET /playback/status`

```json
{
  "is_playing": true,
  "pid": 12345,
  "queue_depth": 2
}
```

---

## 설정 레퍼런스

`hook_voice/config.py`의 `Config` dataclass 기본값 전체.

| JSON 키 | Python 속성 | 기본값 | 설명 |
|---------|------------|--------|------|
| `autoSpeak` | `auto_speak` | `true` | 자동 재생 여부 |
| `minChars` | `min_chars` | `50` | 최소 발화 길이 |
| `voice` | `voice` | `"Sohee"` | 기본 목소리 |
| `summaryModel` | `summary_model` | `"gemini-3.5-flash"` | LLM 모델 |
| `ttsSpeed` | `tts_speed` | `1.1` | afplay -r 배속 |
| `ttsInstruct` | `tts_instruct` | `"밝고 활기차게 말해주세요"` | 발화 스타일 |
| `skillCooldownMinutes` | `skill_cooldown_minutes` | `30` | 스킬 추천 쿨다운 |
| `supertonicPort` | `supertonic_port` | `7777` | TTS 서버 포트 |
| `supertonicTimeoutMs` | `supertonic_timeout_ms` | `20000` | TTS 요청 타임아웃 |
| `allowInsecureTls` | `allow_insecure_tls` | `true` | TLS 검증 스킵 |
| `speechRetouch` | `speech_retouch` | `true` | LLM 텍스트 정제 |
| `usageTracking` | `usage_tracking` | `true` | 사용 통계 수집 |
| `bridgeEnabled` | `bridge_enabled` | `false` | 브리지 WAV 재생 opt-in |
| `bridgeThresholdMs` | `bridge_threshold_ms` | `500` | 브리지 최소 텍스트 길이 |
| `resumeThreshold` | `resume_threshold` | `0.0` | interrupt 재개 임계값 |

**`stt` 블록:**

| JSON 키 | Python 속성 | 기본값 |
|---------|------------|--------|
| `stt.enabled` | `stt.enabled` | `false` |
| `stt.model` | `stt.model` | `mlx-community/whisper-small-mlx` |
| `stt.language` | `stt.language` | `"ko"` |
| `stt.sampleRate` | `stt.sample_rate` | `16000` |
| `stt.announce` | `stt.announce` | `true` |
| `stt.vadInterrupt` | `stt.vad_interrupt` | `false` |

**`voice-map.json` 신규 필드:**

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `meta_voice_id` | `"F1"` | 에이전트명 발화용 기본 목소리 |
| `earcon.enabled` | `true` | 에이전트 전환 earcon 활성화 |
| `earcon.agent_switch` | `"assets/earcon_switch.wav"` | 전환 효과음 경로 |

---

## 테스트

```bash
# 단위 테스트 (401+ passed)
.venv/bin/pytest tests/ --tb=short -q

# TTS 서버 테스트
.venv/bin/pytest tts_server/test_server.py -v

# 전체
.venv/bin/pytest tests/ tts_server/ -v

# 특정 모듈
.venv/bin/pytest tests/learning/ -v          # 자동 학습 레이어
.venv/bin/pytest tests/delivery/ -v          # 우선순위 큐
.venv/bin/pytest tests/event/ -v             # SmartTTS 정책
```

**테스트 패턴:**
- `monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "...")` — 파일 경로 격리
- `AsyncMock` — LLM/TTS HTTP 호출 mock
- `tmp_path` fixture — 파일 I/O 격리

---

## 환경변수

| 변수 | 용도 |
|------|------|
| `HUB_BASE_URL` | HMG 사내 LLM API 베이스 URL |
| `HUB_API_KEY` | LLM API 키 (= ANTHROPIC_API_KEY) |
| `HUB_PROJECT_ID` | Hub 프로젝트 ID (X-Project-Id 헤더) |
| `HF_HUB_OFFLINE` | `1` 고정 — 런타임 HuggingFace 다운로드 차단 |
| `VOICE_PERSONA_DATA_DIR` | 영속화 데이터 경로 오버라이드 |

---

## 변경 이력

### P0 — UX 기반 개선 (2026-07)

| 기능 | 파일 | 설명 |
|------|------|------|
| `/interrupt` + `/playback/status` API | `tts_server/server.py` | afplay SIGTERM→SIGKILL 2단계 중단 |
| stderr 상태 표시 | `hook_voice/hook_handlers.py` | `🎙️ 요약 중...` `▶️ 재생 중` `⚠️ 음성 실패` |
| 코드 블록 자동 축약 | `hook_voice/summarizer.py` | 코드 비중 40%+ → `[N줄 코드]` 형태 |
| TTS 잘림 방지 | `hook_voice/summarizer.py`, `player.py` | `chunk_for_tts()` 80자 문장 분할 |
| `/health` 응답 강화 | `tts_server/server.py` | `model_loaded`, `queue_depth`, `stt_enabled` 추가 |

### P1 — 다성 TTS 고도화 (2026-07)

| 기능 | 파일 | 설명 |
|------|------|------|
| Earcon + `meta_voice_id` | `voice_router.py`, `player.py`, `voice-map.json` | 에이전트 전환 청각 큐 (0.3초 880Hz) |
| 우선순위 큐 HIGH/NORMAL/LOW | `delivery/priority_spool.py` | + 30초 TTL 자동 만료 |
| `chorus voice test` / `chorus doctor` | `hook_handlers.py`, `__main__.py` | 진단·테스트 CLI |

### P2 — 스마트 발화 (2026-07)

| 기능 | 파일 | 설명 |
|------|------|------|
| SmartTTSRouter | `event/policy.py` | 응답 타입 기반 발화 모드·우선순위 자동 결정 |
| 브리지 WAV | `config.py`, `hook_handlers.py`, `assets/` | Stop hook 직후 침묵 제거 opt-in |
| `resumeThreshold` | `config.py`, `tts_server/server.py` | interrupt 후 재개 임계값 opt-in |
| VAD 자동 중단 | `speech_listener.py`, `config.py` | 마이크 발화 감지 시 TTS 중단 opt-in |

### 자동 학습·적응 레이어 (2026-07)

| 기능 | 파일 | 설명 |
|------|------|------|
| 통계 저장소 | `learning/stats_store.py` | JSONL 로컬 수집·조회·삭제 |
| `usageTracking` 설정 | `config.py` | 수집 opt-out (`false`이면 중단) |
| 통계 수집 | `hook_handlers.py` | TTS 완료/중단 시 자동 기록 |
| 분석 엔진 | `learning/advisor.py` | 3가지 규칙 → `Suggestion` 생성 |
| `suggest-config` / `privacy` CLI | `hook_handlers.py`, `__main__.py` | 권장안 출력 + 데이터 삭제 |

---

## 의존성 구조

```
hook_voice
  ├── summarizer.py     ← llm_client.py
  ├── player.py         ← delivery/priority_spool.py
  │                     ← learning/stats_store.py (import)
  ├── hook_handlers.py  ← player.py, summarizer.py, voice_router.py
  │                     ← event/policy.py
  │                     ← learning/stats_store.py, learning/advisor.py
  ├── speech_listener.py ← config.py (SttConfig)
  └── learning/
        ├── stats_store.py  (stdlib only)
        └── advisor.py      ← stats_store.py (Suggestion)

tts_server
  ├── server.py    ← hook_voice.config, hook_voice.speech_listener
  └── supervisor.py ← hook_voice.config, hook_voice.grafana_poller
```

순환 참조 없음. `learning/` 하위는 stdlib 전용 (json, pathlib, time, collections).
