# Safety Net + Observability 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Circuit Breaker(EdgeTTS·Supertonic·LLM) + Structured Logging + Correlation ID를 기존 329개 테스트를 유지하면서 hook flow에 통합한다.

**Architecture:** 점진적 통합(방식 A) — 기존 `hook_handlers → player → llm_client` 경로를 변경하지 않고 CB 래퍼·구조화 로그·metrics/DLQ 연결 레이어를 추가한다. Sprint 1(Task 1·2)은 완전 독립, Sprint 2(Task 3·4·6)는 Sprint 1 완료 후 병렬, Task 5·7은 모두 완료 후 순차.

**Tech Stack:** Python 3.13, asyncio, pytest-asyncio, httpx.AsyncMock, unittest.mock

---

## 파일 맵

| 작업 | 파일 | 상태 |
|------|------|------|
| Task 1 | `hook_voice/observability/circuit_breaker.py` | 신규 |
| Task 1 | `tests/observability/test_circuit_breaker.py` | 신규 |
| Task 2 | `hook_voice/observability/context.py` | 신규 |
| Task 2 | `hook_voice/observability/structured_log.py` | 신규 |
| Task 2 | `tests/observability/test_context.py` | 신규 |
| Task 2 | `tests/observability/test_structured_log.py` | 신규 |
| Task 3 | `hook_voice/player.py` | 수정 (CB 추가) |
| Task 4 | `hook_voice/llm_client.py` | 수정 (CB 추가) |
| Task 5 | `hook_voice/hook_handlers.py` | 수정 (metrics·DLQ·log 연결) |
| Task 6 | `tts_server/server.py` | 수정 (/metrics/json 확장) |

---

## Task 1: CircuitBreaker 구현

**Sprint 1 — 독립 실행 가능**

**Files:**
- Create: `hook_voice/observability/circuit_breaker.py`
- Create: `tests/observability/test_circuit_breaker.py`

- [ ] **Step 1: 테스트 파일 작성**

```python
# tests/observability/test_circuit_breaker.py
import asyncio
import pytest
from unittest.mock import AsyncMock

from hook_voice.observability.circuit_breaker import (
    CircuitBreaker, CircuitBreakerConfig, CBState, get_circuit_breaker, _breakers,
)


@pytest.fixture(autouse=True)
def clear_breakers():
    _breakers.clear()
    yield
    _breakers.clear()


@pytest.fixture
def cb():
    return CircuitBreaker("test", CircuitBreakerConfig(failure_threshold=2, recovery_timeout=0.05))


@pytest.mark.asyncio
async def test_closed_success_returns_result(cb):
    result = await cb.call(AsyncMock(return_value="ok"))
    assert result == "ok"
    assert cb.state == CBState.CLOSED


@pytest.mark.asyncio
async def test_open_after_threshold(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    assert cb.state == CBState.OPEN


@pytest.mark.asyncio
async def test_open_fast_fail_returns_fallback(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    result = await cb.call(AsyncMock(return_value="ok"), fallback="default")
    assert result == "default"


@pytest.mark.asyncio
async def test_open_fast_fail_does_not_call_fn(cb):
    fail_fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fail_fn)
    probe = AsyncMock(return_value="ok")
    await cb.call(probe, fallback=None)
    probe.assert_not_called()


@pytest.mark.asyncio
async def test_half_open_after_recovery_timeout(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    await asyncio.sleep(0.1)
    result = await cb.call(AsyncMock(return_value="ok"))
    assert result == "ok"
    assert cb.state == CBState.CLOSED


@pytest.mark.asyncio
async def test_half_open_failure_goes_back_to_open(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    await asyncio.sleep(0.1)
    with pytest.raises(ValueError):
        await cb.call(AsyncMock(side_effect=ValueError("still failing")))
    assert cb.state == CBState.OPEN


@pytest.mark.asyncio
async def test_success_resets_failure_count(cb):
    fn_fail = AsyncMock(side_effect=ValueError("fail"))
    with pytest.raises(ValueError):
        await cb.call(fn_fail)
    assert cb.state == CBState.CLOSED
    await cb.call(AsyncMock(return_value="ok"))
    # 실패 카운트 리셋됐으므로 다시 1번 실패해도 OPEN 안 됨
    with pytest.raises(ValueError):
        await cb.call(fn_fail)
    assert cb.state == CBState.CLOSED


def test_get_circuit_breaker_singleton():
    a = get_circuit_breaker("edge_tts")
    b = get_circuit_breaker("edge_tts")
    assert a is b


def test_get_circuit_breaker_different_names():
    a = get_circuit_breaker("edge_tts")
    b = get_circuit_breaker("supertonic")
    assert a is not b


def test_reset():
    cb = CircuitBreaker("r", CircuitBreakerConfig(failure_threshold=1))
    cb._state = CBState.OPEN
    cb.reset()
    assert cb.state == CBState.CLOSED
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/observability/test_circuit_breaker.py -v
```

Expected: `ImportError: cannot import name 'CircuitBreaker'`

- [ ] **Step 3: 구현 파일 작성**

```python
# hook_voice/observability/circuit_breaker.py
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

_log = logging.getLogger(__name__)


class CBState(str, Enum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


@dataclass
class CircuitBreakerConfig:
    failure_threshold: int = 3
    recovery_timeout: float = 30.0
    half_open_max_calls: int = 1


class CircuitBreaker:
    """asyncio 비동기 Circuit Breaker."""

    def __init__(self, name: str, config: CircuitBreakerConfig | None = None) -> None:
        self.name = name
        self._cfg = config or CircuitBreakerConfig()
        self._state = CBState.CLOSED
        self._failure_count = 0
        self._opened_at: float = 0.0
        self._half_open_calls = 0
        self._lock = asyncio.Lock()

    @property
    def state(self) -> CBState:
        return self._state

    async def call(
        self, fn: Callable[..., Any], *args: Any, fallback: Any = None, **kwargs: Any
    ) -> Any:
        """fn 실행. OPEN이면 fallback 반환. 실패 시 상태 업데이트 후 예외 전파."""
        async with self._lock:
            if self._state == CBState.OPEN:
                if time.time() - self._opened_at >= self._cfg.recovery_timeout:
                    self._state = CBState.HALF_OPEN
                    self._half_open_calls = 0
                    _log.info("[CB:%s] OPEN → HALF_OPEN", self.name)
                else:
                    _log.debug("[CB:%s] fast-fail (OPEN)", self.name)
                    return fallback() if callable(fallback) else fallback

            if self._state == CBState.HALF_OPEN:
                if self._half_open_calls >= self._cfg.half_open_max_calls:
                    return fallback() if callable(fallback) else fallback
                self._half_open_calls += 1

        try:
            result = await fn(*args, **kwargs)
        except Exception:
            async with self._lock:
                self._failure_count += 1
                if self._state == CBState.HALF_OPEN:
                    self._state = CBState.OPEN
                    self._opened_at = time.time()
                    _log.warning("[CB:%s] HALF_OPEN → OPEN (재시도 실패)", self.name)
                elif self._failure_count >= self._cfg.failure_threshold:
                    self._state = CBState.OPEN
                    self._opened_at = time.time()
                    _log.warning(
                        "[CB:%s] CLOSED → OPEN (연속 실패 %d회)", self.name, self._failure_count
                    )
            raise

        async with self._lock:
            if self._state == CBState.HALF_OPEN:
                self._state = CBState.CLOSED
                self._failure_count = 0
                _log.info("[CB:%s] HALF_OPEN → CLOSED (복구)", self.name)
            elif self._state == CBState.CLOSED:
                self._failure_count = 0
        return result

    def reset(self) -> None:
        self._state = CBState.CLOSED
        self._failure_count = 0
        self._opened_at = 0.0
        self._half_open_calls = 0


_breakers: dict[str, CircuitBreaker] = {}


def get_circuit_breaker(
    name: str, config: CircuitBreakerConfig | None = None
) -> CircuitBreaker:
    if name not in _breakers:
        _breakers[name] = CircuitBreaker(name, config)
    return _breakers[name]
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/observability/test_circuit_breaker.py -v
```

Expected: 11 passed

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/observability/circuit_breaker.py tests/observability/test_circuit_breaker.py
git commit -m "feat: CircuitBreaker 구현 — CLOSED/OPEN/HALF_OPEN 상태 머신"
```

---

## Task 2: HookContext + StructuredLog 구현

**Sprint 1 — Task 1과 병렬 가능**

**Files:**
- Create: `hook_voice/observability/context.py`
- Create: `hook_voice/observability/structured_log.py`
- Create: `tests/observability/test_context.py`
- Create: `tests/observability/test_structured_log.py`

- [ ] **Step 1: 테스트 파일 두 개 작성**

```python
# tests/observability/test_context.py
import os
import pytest
from unittest.mock import patch

from hook_voice.observability.context import get_or_create_context


@pytest.fixture(autouse=True)
def isolate_seq_file(tmp_path):
    seq_file = tmp_path / "hook_seq.txt"
    with patch("hook_voice.observability.context._SEQ_FILE", seq_file):
        yield seq_file


def test_correlation_id_format():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "abcdef1234567890"}):
        ctx = get_or_create_context()
    assert ctx.correlation_id == "abcdef12:0001"


def test_seq_increments_across_calls():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "abcdef1234567890"}):
        ctx1 = get_or_create_context()
        ctx2 = get_or_create_context()
    assert ctx2.seq == ctx1.seq + 1
    assert ctx2.correlation_id == "abcdef12:0002"


def test_no_session_id_uses_unknown():
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
    with patch.dict(os.environ, env, clear=True):
        ctx = get_or_create_context()
    assert ctx.session_id == "00000000"
    assert ctx.correlation_id.startswith("00000000:")


def test_seq_resets_on_new_session():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "aaaaaaaaaaaaaaaa"}):
        ctx1 = get_or_create_context()
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "bbbbbbbbbbbbbbbb"}):
        ctx2 = get_or_create_context()
    assert ctx2.seq == 1
```

```python
# tests/observability/test_structured_log.py
import json
import os
import pytest
from unittest.mock import patch

from hook_voice.observability.context import HookContext
from hook_voice.observability.structured_log import log_event


@pytest.fixture
def ctx():
    return HookContext(
        session_id="abcdef1234567890", seq=7, correlation_id="abcdef12:0007"
    )


def test_outputs_valid_json(ctx, capsys):
    log_event("hook_start", ctx)
    out = capsys.readouterr().err
    data = json.loads(out)
    assert data["event"] == "hook_start"
    assert data["correlation_id"] == "abcdef12:0007"
    assert data["level"] == "INFO"
    assert "ts" in data


def test_includes_extra_fields(ctx, capsys):
    log_event("tts_completed", ctx, {"latency_ms": 312.5, "text_len": 50})
    data = json.loads(capsys.readouterr().err)
    assert data["latency_ms"] == 312.5
    assert data["text_len"] == 50


def test_level_filter_suppresses_info_when_warning(ctx, capsys):
    with patch.dict(os.environ, {"VOICE_LOG_LEVEL": "WARNING"}):
        log_event("hook_start", ctx, level="INFO")
    assert capsys.readouterr().err == ""


def test_level_filter_passes_warning(ctx, capsys):
    with patch.dict(os.environ, {"VOICE_LOG_LEVEL": "WARNING"}):
        log_event("tts_failed", ctx, level="WARNING")
    data = json.loads(capsys.readouterr().err)
    assert data["level"] == "WARNING"


def test_outputs_to_stderr_not_stdout(ctx, capsys):
    log_event("hook_start", ctx)
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err != ""
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/observability/test_context.py tests/observability/test_structured_log.py -v
```

Expected: `ImportError: cannot import name 'get_or_create_context'`

- [ ] **Step 3: context.py 작성**

```python
# hook_voice/observability/context.py
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

_SEQ_FILE = Path.home() / ".local" / "share" / "voice-persona" / "hook_seq.txt"
_UNKNOWN_SESSION = "00000000"


@dataclass
class HookContext:
    session_id: str
    seq: int
    correlation_id: str


def _read_seq(full_sid: str) -> int:
    try:
        if _SEQ_FILE.exists():
            parts = _SEQ_FILE.read_text().strip().split(":")
            if len(parts) == 2 and parts[0] == full_sid:
                return int(parts[1])
    except Exception:
        pass
    return 0


def _write_seq(full_sid: str, seq: int) -> None:
    try:
        _SEQ_FILE.parent.mkdir(parents=True, exist_ok=True)
        _SEQ_FILE.write_text(f"{full_sid}:{seq}")
    except Exception:
        pass


def get_or_create_context() -> HookContext:
    """CLAUDE_CODE_SESSION_ID 환경변수에서 세션 ID를 읽어 HookContext를 생성한다."""
    raw_sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    full_sid = raw_sid if raw_sid else _UNKNOWN_SESSION
    short_sid = full_sid[:8]

    seq = _read_seq(full_sid) + 1
    _write_seq(full_sid, seq)

    return HookContext(
        session_id=full_sid,
        seq=seq,
        correlation_id=f"{short_sid}:{seq:04d}",
    )
```

- [ ] **Step 4: structured_log.py 작성**

```python
# hook_voice/observability/structured_log.py
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

from .context import HookContext

_LEVEL_MAP = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}


def _current_level() -> int:
    return _LEVEL_MAP.get(os.environ.get("VOICE_LOG_LEVEL", "INFO").upper(), 20)


def log_event(
    event: str,
    ctx: HookContext,
    extra: dict[str, Any] | None = None,
    level: str = "INFO",
) -> None:
    """JSON Lines 형식으로 stderr에 구조화 로그를 출력한다."""
    if _LEVEL_MAP.get(level.upper(), 20) < _current_level():
        return

    now = time.time()
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now))
    ms = int(now * 1000) % 1000

    record: dict[str, Any] = {
        "ts": f"{ts}.{ms:03d}Z",
        "level": level.upper(),
        "correlation_id": ctx.correlation_id,
        "event": event,
    }
    if extra:
        record.update(extra)

    try:
        print(json.dumps(record, ensure_ascii=False), file=sys.stderr)
    except Exception:
        pass
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/observability/test_context.py tests/observability/test_structured_log.py -v
```

Expected: 9 passed

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/observability/context.py hook_voice/observability/structured_log.py \
        tests/observability/test_context.py tests/observability/test_structured_log.py
git commit -m "feat: HookContext + StructuredLog — correlation_id 기반 JSON 구조화 로그"
```

---

## Task 3: player.py에 Circuit Breaker 적용

**Sprint 2 — Task 1 완료 후 실행**

**Files:**
- Modify: `hook_voice/player.py`

- [ ] **Step 1: 기존 player 테스트 통과 기준선 확인**

```bash
.venv/bin/pytest tests/test_player.py -v
```

Expected: 모두 통과 (기준선 기록)

- [ ] **Step 2: CB 통합 테스트 추가**

`tests/test_player.py` 파일 하단에 다음 테스트를 추가한다:

```python
# tests/test_player.py 하단에 추가

from hook_voice.observability.circuit_breaker import _breakers, CBState


@pytest.fixture(autouse=True)
def reset_cbs():
    """각 테스트 후 CB 상태 초기화."""
    yield
    for cb in _breakers.values():
        cb.reset()
    _breakers.clear()


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_opens_after_failures(monkeypatch, tmp_path):
    """EdgeTTS가 3회 연속 실패하면 CB가 OPEN으로 전환된다."""
    import asyncio
    from hook_voice import player as _player

    call_count = 0

    async def fail_edge(text):
        nonlocal call_count
        call_count += 1
        raise OSError("edge fail")

    monkeypatch.setattr(_player, "_generate_edge", fail_edge)
    monkeypatch.setattr(_player, "_venv_python", lambda: tmp_path / "python")
    (tmp_path / "python").touch()
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())
    monkeypatch.delenv("VOICE_PERSONA_OFFLINE", raising=False)

    for _ in range(3):
        await _player.speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)

    from hook_voice.observability.circuit_breaker import get_circuit_breaker
    assert get_circuit_breaker("edge_tts").state == CBState.OPEN


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_open_skips_generate(monkeypatch, tmp_path):
    """EdgeTTS CB가 OPEN 상태면 _generate_edge를 호출하지 않는다."""
    from hook_voice import player as _player
    from hook_voice.observability.circuit_breaker import get_circuit_breaker, CBState

    cb = get_circuit_breaker("edge_tts")
    import time
    cb._state = CBState.OPEN
    cb._opened_at = time.time()  # 방금 열림 → recovery_timeout(30s) 아직 안 지남

    called = []
    async def should_not_call(text):
        called.append(text)
        return tmp_path / "test.mp3"

    monkeypatch.setattr(_player, "_generate_edge", should_not_call)
    monkeypatch.setattr(_player, "_venv_python", lambda: tmp_path / "python")
    (tmp_path / "python").touch()
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())
    monkeypatch.delenv("VOICE_PERSONA_OFFLINE", raising=False)

    await _player.speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)
    assert called == []


@pytest.mark.asyncio
async def test_speak_agent_supertonic_cb_opens_after_failures(monkeypatch):
    """Supertonic이 3회 연속 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice import player as _player

    monkeypatch.setattr(_player, "_is_supertonic_alive", AsyncMock(return_value=True))

    async def fail_st(*args, **kwargs):
        raise OSError("supertonic fail")

    monkeypatch.setattr(_player, "_generate_supertonic", fail_st)
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())

    for _ in range(3):
        await _player.speak_agent("test", "M2", port=7788, speed=1.0)

    from hook_voice.observability.circuit_breaker import get_circuit_breaker
    assert get_circuit_breaker("supertonic").state == CBState.OPEN
```

- [ ] **Step 3: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_player.py::test_speak_hook_edge_cb_opens_after_failures -v
```

Expected: FAILED (AttributeError 또는 AssertionError — CB 아직 없음)

- [ ] **Step 4: player.py 수정 — import 추가**

`hook_voice/player.py` 상단 import 블록에 추가:

```python
from .observability.circuit_breaker import get_circuit_breaker
```

- [ ] **Step 5: speak_hook에 CB 적용**

`speak_hook` 함수에서 다음 블록을 교체한다:

```python
# 교체 전 (speak_hook 내부)
    if not skip_edge and _venv_python().exists():
        try:
            mp3 = await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)
            _enqueue_spool(mp3, speed)
            save_last_message(text)
            return
        except Exception as e:
            _log.warning("Edge generation failed, local fallback: %s", type(e).__name__)
    await _speak_without_edge(text, voice, speed)
```

```python
# 교체 후
    if not skip_edge and _venv_python().exists():
        edge_cb = get_circuit_breaker("edge_tts")

        async def _edge_call() -> Path:
            return await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)

        try:
            mp3 = await edge_cb.call(_edge_call, fallback=None)
            if mp3 is not None:
                _enqueue_spool(mp3, speed)
                save_last_message(text)
                return
        except Exception as e:
            _log.warning("Edge generation failed, local fallback: %s", type(e).__name__)
    await _speak_without_edge(text, voice, speed)
```

- [ ] **Step 6: speak_agent에 CB 적용**

`speak_agent` 함수에서 다음 블록을 교체한다:

```python
# 교체 전 (speak_agent 내부)
    if await _is_supertonic_alive(port):
        try:
            wav_bytes = await asyncio.wait_for(
                _generate_supertonic(text, voice, port, steps=steps, timeout=supertonic_timeout),
                timeout=supertonic_timeout,
            )
            tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
            return
        except Exception as e:
            _log.warning("Supertonic generation failed, generic fallback: %s", type(e).__name__)
    else:
        _log.info("Supertonic unavailable, generic fallback")
    await _speak_without_edge(text, voice, speed, instruct)
```

```python
# 교체 후
    if await _is_supertonic_alive(port):
        st_cb = get_circuit_breaker("supertonic")

        async def _st_call() -> bytes:
            return await asyncio.wait_for(
                _generate_supertonic(text, voice, port, steps=steps, timeout=supertonic_timeout),
                timeout=supertonic_timeout,
            )

        try:
            wav_bytes = await st_cb.call(_st_call, fallback=None)
            if wav_bytes is not None:
                tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
                tmp.write_bytes(wav_bytes)
                _enqueue_spool(tmp, speed)
                save_last_message(text)
                return
        except Exception as e:
            _log.warning("Supertonic generation failed, generic fallback: %s", type(e).__name__)
    else:
        _log.info("Supertonic unavailable, generic fallback")
    await _speak_without_edge(text, voice, speed, instruct)
```

- [ ] **Step 7: 전체 player 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_player.py -v
```

Expected: 모두 통과 (기존 + 신규 CB 테스트)

- [ ] **Step 8: 커밋**

```bash
git add hook_voice/player.py tests/test_player.py
git commit -m "feat: EdgeTTS·Supertonic에 CircuitBreaker 적용"
```

---

## Task 4: llm_client.py에 Circuit Breaker 적용

**Sprint 2 — Task 1 완료 후 Task 3과 병렬 가능**

**Files:**
- Modify: `hook_voice/llm_client.py`

- [ ] **Step 1: 기존 llm_client 테스트 기준선 확인**

```bash
.venv/bin/pytest tests/test_llm_client.py -v
```

Expected: 모두 통과

- [ ] **Step 2: CB 통합 테스트 추가**

`tests/test_llm_client.py` 하단에 다음 테스트를 추가한다:

```python
# tests/test_llm_client.py 하단에 추가

from hook_voice.observability.circuit_breaker import _breakers, CBState


@pytest.fixture(autouse=True)
def reset_llm_cb():
    yield
    if "llm_api" in _breakers:
        _breakers["llm_api"].reset()
    _breakers.clear()


@pytest.mark.asyncio
async def test_chat_completion_cb_opens_after_failures(monkeypatch):
    """LLM API가 3회 연속 실패하면 CB가 OPEN으로 전환된다."""
    import httpx
    from hook_voice import llm_client as _lc

    async def fail(*args, **kwargs):
        raise httpx.ConnectError("conn refused")

    monkeypatch.setattr(_lc, "_do_chat_completion", fail)
    monkeypatch.setenv("HUB_API_KEY", "testkey")

    for _ in range(3):
        result = await _lc.chat_completion([{"role": "user", "content": "hi"}])
        assert result == ""

    from hook_voice.observability.circuit_breaker import get_circuit_breaker
    assert get_circuit_breaker("llm_api").state == CBState.OPEN


@pytest.mark.asyncio
async def test_chat_completion_cb_open_skips_http(monkeypatch):
    """CB OPEN 상태에서 _do_chat_completion을 호출하지 않는다."""
    from hook_voice import llm_client as _lc
    from hook_voice.observability.circuit_breaker import get_circuit_breaker
    import time

    cb = get_circuit_breaker("llm_api")
    cb._state = CBState.OPEN
    cb._opened_at = time.time()

    called = []

    async def should_not_call(*args, **kwargs):
        called.append(True)
        return "should_not_reach"

    monkeypatch.setattr(_lc, "_do_chat_completion", should_not_call)
    monkeypatch.setenv("HUB_API_KEY", "testkey")

    result = await _lc.chat_completion([{"role": "user", "content": "hi"}])
    assert result == ""
    assert called == []
```

- [ ] **Step 3: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_llm_client.py::test_chat_completion_cb_opens_after_failures -v
```

Expected: FAILED (AttributeError — `_do_chat_completion` 없음)

- [ ] **Step 4: llm_client.py 수정**

`hook_voice/llm_client.py`에서 import 블록에 추가:

```python
from .observability.circuit_breaker import get_circuit_breaker
```

기존 `chat_completion` 함수 전체를 다음으로 교체한다:

```python
async def _do_chat_completion(
    messages: list[dict],
    model: str,
    **kwargs,
) -> str:
    """실제 HTTP 호출. chat_completion의 CB 내부 실행 함수."""
    base_url = os.environ.get("HUB_BASE_URL", "")
    async with httpx.AsyncClient(
        base_url=base_url,
        headers=_make_headers(),
        verify=_verify_tls(),
        timeout=30.0,
    ) as client:
        resp = await client.post(
            "/chat/completions",
            json={"model": model, "messages": messages, **kwargs},
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"].strip()


async def chat_completion(
    messages: list[dict],
    model: str = DEFAULT_MODEL,
    **kwargs,
) -> str:
    """OpenAI 호환 chat completion — 응답 텍스트 반환, 실패 시 빈 문자열."""
    api_key = os.environ.get("HUB_API_KEY", "")
    if not api_key:
        _log.warning("HUB_API_KEY 미설정 — LLM 호출 건너뜀")
        return ""

    cb = get_circuit_breaker("llm_api")
    try:
        result = await cb.call(_do_chat_completion, messages, model, fallback="", **kwargs)
        return result or ""
    except httpx.TimeoutException as e:
        _log.warning("LLM timeout: %s", type(e).__name__)
        return ""
    except httpx.ConnectError as e:
        _log.warning("LLM connect error: %s", type(e).__name__)
        return ""
    except httpx.HTTPStatusError as e:
        _log.warning("LLM HTTP error %s: %.100s", e.response.status_code, e.response.text)
        return ""
    except Exception as e:
        _log.warning("LLM unexpected error: %s", type(e).__name__)
        return ""
```

- [ ] **Step 5: 전체 llm_client 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_llm_client.py -v
```

Expected: 모두 통과

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/llm_client.py tests/test_llm_client.py
git commit -m "feat: LLM API에 CircuitBreaker 적용 — fast-fail 및 상태 추적"
```

---

## Task 5: hook_handlers.py — metrics·DLQ·log 연결

**Sprint 3 — Task 1·2·3·4 완료 후**

**Files:**
- Modify: `hook_voice/hook_handlers.py`

- [ ] **Step 1: 기존 hook_handlers 테스트 기준선 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: 모두 통과 (기준선 기록)

- [ ] **Step 2: hook_handlers.py import 블록 상단에 추가**

`hook_voice/hook_handlers.py`에서 기존 `from .config import Config` 줄 뒤에 추가:

```python
import time as _time

from .observability.context import get_or_create_context
from .observability.structured_log import log_event
from .observability.metrics import get_registry
from .observability.dlq import get_dlq_store
```

- [ ] **Step 3: handle_hook 수정**

`handle_hook` 함수 전체를 다음으로 교체한다:

```python
async def handle_hook(raw: str, config: Config) -> None:
    hook_ctx = get_or_create_context()
    log_event("hook_start", hook_ctx, {"source": "stop_hook"})
    get_registry().record_event("hook", "stop")

    text = ""
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", "")
    except Exception:
        pass
    if not text:
        tp = _derive_transcript_path()
        if tp:
            text = get_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        if config.speech_retouch:
            pipeline = get_default_pipeline()
            speech_ctx = await pipeline.process(summary)
            summary = speech_ctx.text
        start = _time.time()
        try:
            await speak_hook(summary, config.voice, config.tts_speed,
                             edge_timeout=config.edge_timeout_ms / 1000)
            latency_ms = (_time.time() - start) * 1000
            get_registry().record_tts_latency(latency_ms)
            log_event("tts_completed", hook_ctx, {
                "latency_ms": round(latency_ms, 1),
                "text_len": len(summary),
            })
        except Exception as exc:
            log_event("tts_failed", hook_ctx, {"error": str(exc)}, level="WARNING")
            get_dlq_store().push(
                event_id=hook_ctx.correlation_id,
                failure_stage="speak_hook",
                failure_detail=str(exc),
                raw_text=summary[:200],
                source="stop_hook",
            )
```

- [ ] **Step 4: handle_subagent_stop 수정**

`handle_subagent_stop` 함수 전체를 다음으로 교체한다:

```python
async def handle_subagent_stop(raw: str, agent_type: str, config: Config) -> None:
    hook_ctx = get_or_create_context()
    log_event("hook_start", hook_ctx, {"source": "subagent_stop", "agent_type": agent_type})
    get_registry().record_event("subagent", "stop")

    text = raw
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", raw)
        if not agent_type:
            tp = data.get("transcript_path", "")
            if tp:
                agent_type = extract_last_agent_type(Path(tp))
    except Exception:
        pass
    if len(text) < config.min_chars:
        return
    vm = load_voice_map()
    voice = resolve_voice(agent_type, vm)
    voice_name = resolve_voice_name(agent_type, vm)
    label = get_agent_label(agent_type, vm)
    instruct = resolve_instruct(agent_type, vm)
    category = resolve_category(agent_type, vm)
    steps = vm.get("supertonic", {}).get("steps", 12)
    one_liner = await extract_one_liner(text, config.summary_model)
    if config.speech_retouch:
        pipeline = get_default_pipeline()
        speech_ctx = await pipeline.process(one_liner)
        one_liner = speech_ctx.text
    tag = select_expression_tag(one_liner, category)
    prefix = f"{tag} " if tag else ""
    speak_text = f"{prefix}{label} {voice_name}입니다. {one_liner}"
    start = _time.time()
    try:
        await speak_agent(speak_text, voice, config.supertonic_port, config.tts_speed, instruct,
                          steps=steps, supertonic_timeout=config.supertonic_timeout_ms / 1000)
        latency_ms = (_time.time() - start) * 1000
        get_registry().record_tts_latency(latency_ms)
        log_event("tts_completed", hook_ctx, {
            "latency_ms": round(latency_ms, 1),
            "text_len": len(speak_text),
            "agent_type": agent_type,
        })
    except Exception as exc:
        log_event("tts_failed", hook_ctx, {"error": str(exc), "agent_type": agent_type}, level="WARNING")
        get_dlq_store().push(
            event_id=hook_ctx.correlation_id,
            failure_stage="speak_agent",
            failure_detail=str(exc),
            raw_text=speak_text[:200],
            source="subagent_stop",
        )
```

- [ ] **Step 5: 전체 hook_handlers 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: 기존 테스트 모두 통과

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/hook_handlers.py
git commit -m "feat: hook_handlers에 metrics·DLQ·structured log 연결"
```

---

## Task 6: server.py /metrics/json 확장

**Sprint 2·3 — Task 1 완료 후 Task 5와 병렬 가능**

**Files:**
- Modify: `tts_server/server.py`

- [ ] **Step 1: 기존 server 테스트 기준선 확인**

```bash
.venv/bin/pytest tts_server/test_server.py -v
```

Expected: 모두 통과

- [ ] **Step 2: /metrics/json 엔드포인트 수정**

`tts_server/server.py`에서 `async def metrics_json()` 함수를 다음으로 교체한다:

```python
@app.get("/metrics/json")
async def metrics_json():
    from hook_voice.observability.circuit_breaker import _breakers
    snap = _get_metrics().snapshot()
    snap["circuit_breakers"] = {
        name: cb.state.value for name, cb in _breakers.items()
    }
    snap["dlq_pending"] = _get_dlq_store().stats().get("pending", 0)
    return snap
```

- [ ] **Step 3: server 테스트에 circuit_breakers 필드 검증 추가**

`tts_server/test_server.py`에서 `/metrics/json` 관련 테스트를 찾아 다음 assertion을 추가한다:

```python
# 기존 test_metrics_json 류 테스트 내부에 추가
response = client.get("/metrics/json")
data = response.json()
assert "circuit_breakers" in data
assert "dlq_pending" in data
assert isinstance(data["dlq_pending"], int)
```

만약 `/metrics/json` 전용 테스트가 없다면 다음 테스트를 추가한다:

```python
def test_metrics_json_includes_cb_and_dlq(client):
    response = client.get("/metrics/json")
    assert response.status_code == 200
    data = response.json()
    assert "circuit_breakers" in data
    assert "dlq_pending" in data
    assert isinstance(data["dlq_pending"], int)
    assert "uptime_seconds" in data
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tts_server/test_server.py -v
```

Expected: 모두 통과

- [ ] **Step 5: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "feat: /metrics/json에 circuit_breaker 상태·DLQ pending 카운트 추가"
```

---

## Task 7: 전체 회귀 검증

**최종 — 모든 Task 완료 후**

- [ ] **Step 1: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v --tb=short
```

Expected: **모두 통과** (329개 + 신규 테스트)

- [ ] **Step 2: 실패 테스트 있으면 수정**

실패 테스트가 있으면 해당 Task 담당 에이전트가 수정한다. 신규 테스트 실패는 구현 버그, 기존 테스트 실패는 회귀(regression)이므로 즉시 원인 파악.

- [ ] **Step 3: 최종 커밋**

```bash
git add -A
git status  # 미커밋 파일 없는지 확인
git commit -m "chore: Safety Net + Observability 통합 완료 — 전체 테스트 통과" --allow-empty
```

---

## 병렬 실행 지도

```
Sprint 1 ───────────────────────────────────────
  [Agent A] Task 1: circuit_breaker.py
  [Agent B] Task 2: context.py + structured_log.py
                ↓ 둘 다 완료
Sprint 2 ───────────────────────────────────────
  [Agent C] Task 3: player.py CB
  [Agent D] Task 4: llm_client.py CB
  [Agent E] Task 6: server.py /metrics 확장
                ↓ 모두 완료
Sprint 3 ───────────────────────────────────────
  [Agent F] Task 5: hook_handlers.py 연결
                ↓
  [Agent G] Task 7: 전체 회귀 검증
```
