# Safety Net + Observability 설계 스펙

**날짜**: 2026-05-31  
**프로젝트**: summary-voice-mcp  
**델파이 세션**: 289fff346984450ba3ab7a858e056395  
**방식**: 점진적 통합 (방식 A)

---

## 목표

델파이 Phase 1 (Safety Net) + Phase 2 (Observability) 결론을 적용한다.  
기존 329개 테스트를 유지하면서, 이미 만들어진 `event`·`delivery`·`observability` 패키지를 실제 hook flow에 연결하고, Circuit Breaker와 Structured Logging을 신규 추가한다.

---

## 1. 아키텍처 개요

```
[현재]
hook_handlers → summarizer → player(EdgeTTS/Supertonic) → /tmp/tts-spool/

[추가 레이어]
hook_handlers
  ├── HookContext (correlation_id = session_id[:8]:seq#)  ← NEW
  ├── StructuredLogger (JSON → stderr)                   ← NEW
  ├── MetricsRegistry (event count, TTS latency)         ← WIRE
  ├── CircuitBreaker (EdgeTTS / Supertonic / LLM)       ← NEW
  └── DLQStore (실패 이벤트 → ~/.local/share/.../dlq.db) ← WIRE
```

### 신규 파일

| 파일 | 역할 |
|------|------|
| `hook_voice/observability/circuit_breaker.py` | 상태 머신 기반 CB |
| `hook_voice/observability/structured_log.py` | JSON 구조화 로거 |
| `hook_voice/observability/context.py` | Correlation ID 컨텍스트 |

### 수정 파일

| 파일 | 변경 내용 |
|------|----------|
| `hook_voice/hook_handlers.py` | metrics·DLQ·log 연결 |
| `hook_voice/player.py` | EdgeTTS·Supertonic에 CB 적용 |
| `hook_voice/llm_client.py` | LLM 호출에 CB 적용 |
| `tts_server/server.py` | `/metrics` 응답에 CB 상태 포함 |

---

## 2. Circuit Breaker

### 상태 머신

```
CLOSED ──(연속 failure_threshold회 실패)──► OPEN
OPEN ──(recovery_timeout 경과)──────────► HALF_OPEN
HALF_OPEN ──(시험 호출 성공)────────────► CLOSED
HALF_OPEN ──(시험 호출 실패)────────────► OPEN
```

### 파라미터

```python
@dataclass
class CircuitBreakerConfig:
    failure_threshold: int = 3      # 연속 실패 횟수
    recovery_timeout: float = 30.0  # OPEN → HALF_OPEN 대기(초)
    half_open_max_calls: int = 1    # 시험 호출 수
```

### 인터페이스

```python
class CircuitBreaker:
    async def call(self, fn: Callable, *args, fallback=None, **kwargs) -> Any:
        """OPEN 상태에서 fallback 즉시 반환 (fast-fail)."""

    @property
    def state(self) -> Literal["CLOSED", "OPEN", "HALF_OPEN"]: ...

    def reset(self) -> None: ...
```

### 대상별 Fallback

| 대상 | Fallback |
|------|---------|
| EdgeTTS | `HTTP POST localhost:7777/speak` |
| Supertonic | EdgeTTS CB로 재시도 |
| LLM API | 규칙 기반 `_rule_based_summary()` |

### DLQ 연동

OPEN 전환 시:
```python
dlq.push(
    event_id=correlation_id,
    failure_stage="circuit_open",
    failure_detail=f"{name}: {last_error}",
    source=source,
)
```

---

## 3. Structured Logging + Correlation ID

### Correlation ID 형식

`{session_id[:8]}:{seq:04d}`  
예: `a1b2c3d4:0007`

`seq`는 `~/.local/share/voice-persona/hook_seq.txt`에 세션 기준으로 영속화.

### HookContext

```python
@dataclass
class HookContext:
    session_id: str
    seq: int
    correlation_id: str  # f"{session_id[:8]}:{seq:04d}"

def get_or_create_context() -> HookContext:
    """환경변수 CLAUDE_CODE_SESSION_ID 읽어 컨텍스트 생성."""
```

### 구조화 로그 형식

```json
{
  "ts": "2026-05-31T14:30:00.123Z",
  "level": "INFO",
  "correlation_id": "a1b2c3d4:0007",
  "event": "tts_completed",
  "tts_engine": "edge_tts",
  "text_len": 250,
  "latency_ms": 312
}
```

### 기록 이벤트 목록

| event | 시점 |
|-------|------|
| `hook_start` | handle_hook / handle_subagent_stop 진입 |
| `tts_started` | TTS 호출 직전 |
| `tts_completed` | TTS 완료 (latency_ms 포함) |
| `tts_failed` | TTS 실패 (error 포함) |
| `cb_state_change` | CB 상태 전이 |
| `dlq_push` | DLQ 적재 |

출력: **stderr** (JSON Lines 형식), `VOICE_LOG_LEVEL` 환경변수로 제어 (기본 INFO).

---

## 4. 이벤트 파이프라인 연결

### hook_handlers 변경 패턴

```python
async def handle_hook(raw: str, config: Config) -> None:
    ctx = get_or_create_context()
    log_event("hook_start", ctx, {"source": "hook"})
    metrics.record_event("hook", "stop")

    try:
        # 기존 summarizer / player 호출 (변경 없음)
        start = time.time()
        await speak_hook(text, config)
        metrics.record_tts_latency((time.time() - start) * 1000)
        log_event("tts_completed", ctx, {"latency_ms": ...})
    except Exception as exc:
        log_event("tts_failed", ctx, {"error": str(exc)})
        dlq.push(event_id=ctx.correlation_id, failure_stage="speak_hook", ...)
```

### `/metrics` 응답 확장

```json
{
  "circuit_breakers": {
    "edge_tts": "CLOSED",
    "supertonic": "CLOSED",
    "llm_api": "CLOSED"
  },
  "dlq_pending": 2,
  "uptime_seconds": 3600,
  ...기존 필드...
}
```

---

## 5. 테스트 전략

| 테스트 파일 | 대상 | 독립 |
|-------------|------|------|
| `tests/observability/test_circuit_breaker.py` | CB 상태 전이 (CLOSED→OPEN→HALF_OPEN→CLOSED) | ✅ |
| `tests/observability/test_structured_log.py` | JSON 출력 파싱, 필드 검증 | ✅ |
| `tests/observability/test_context.py` | correlation_id 형식, seq 증가 | ✅ |
| `tests/test_hook_handlers.py` (기존 확장) | metrics·DLQ mock 주입 후 호출 검증 | ✅ |

모든 테스트는 `pytest-asyncio`, `AsyncMock`으로 실제 외부 호출 없이 동작해야 함.  
기존 329개 테스트가 수정 후에도 모두 통과해야 함.

---

## 6. 구현 순서 (서브에이전트 병렬)

```
Sprint 1 (병렬)
  [A] circuit_breaker.py + test_circuit_breaker.py
  [B] structured_log.py + context.py + test_structured_log.py + test_context.py

Sprint 2 (병렬, Sprint 1 완료 후)
  [C] player.py CB 적용 + llm_client.py CB 적용
  [D] hook_handlers.py metrics·DLQ·log 연결

Sprint 3 (통합, Sprint 2 완료 후)
  [E] tts_server/server.py /metrics 확장
  [F] 전체 pytest 통과 확인 + 기존 테스트 회귀 검증
```

---

## 7. 비기능 요건

- **성능**: CB 판단 오버헤드 < 1ms
- **스레드 안전**: CB 상태 변경은 `asyncio.Lock` 보호
- **no-op 폴백**: OTel SDK 없어도 동작 (기존 otel.py 패턴 동일)
- **하위 호환**: 기존 `.voice.json` 설정 변경 없음
- **환경변수 제어**: `VOICE_LOG_LEVEL` (DEBUG/INFO/WARNING), `VOICE_CB_DISABLED=1`로 CB 전체 비활성화 가능
