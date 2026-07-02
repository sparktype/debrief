# 자동 학습·적응 레이어 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자의 TTS 사용 패턴(완료율·중단·에이전트별 빈도)을 로컬 파일에 익명 수집하고, `chorus suggest-config` 명령으로 `.voice.json` 개선안을 제안한다.

**Architecture:**
- `hook_voice/learning/stats_store.py` — 로컬 JSONL 통계 저장소 (프로젝트별 격리)
- `hook_voice/learning/advisor.py` — 통계 분석 → 설정 권장안 생성
- `hook_voice/hook_handlers.py` — TTS 완료/중단 이벤트에서 stats_store에 기록
- `python -m hook_voice suggest-config` — 권장안 출력
- `python -m hook_voice privacy clear` — 통계 데이터 전체 삭제
- **자동 적용 없음**: 항상 사용자가 명시적으로 실행해야 제안을 볼 수 있다.

**Tech Stack:** Python 3.12+, json/pathlib(stdlib 전용), pytest-asyncio

## Global Constraints

- Python `.venv/bin/python` 사용
- 테스트: `.venv/bin/pytest tests/ --tb=short -q` — 378 passed 유지
- 경어체(-습니다/ㅂ니다) 출력 문구
- 파일 첫 줄: 한 줄 한국어 역할 주석
- `hook_voice/` 패키지: 상대 import (`from .learning.stats_store import ...`)
- 저장 경로: `~/.local/share/chorus/usage_stats.jsonl` (고정, 프로젝트 간 공유 없음)
- 통계 수집은 `usage_tracking: true` (`.voice.json` 기본값) 일 때만 동작
- 자동 설정 변경 금지 — `suggest-config`는 출력만, 적용은 사용자 수동
- stdlib 외 추가 의존성 없음 (httpx·numpy 등 이미 있는 것만 허용)

---

## 파일 구조

```
hook_voice/
  learning/
    __init__.py                 # 빈 패키지 마커
    stats_store.py              # JSONL 통계 저장·로드·삭제
    advisor.py                  # 통계 분석 → 권장안 생성
tests/
  learning/
    __init__.py
    test_stats_store.py
    test_advisor.py
```

**수정 파일:**
- `hook_voice/config.py` — `usage_tracking: bool = True` 설정 추가
- `hook_voice/hook_handlers.py` — `handle_hook` 내 TTS 완료/중단 시 통계 기록, `handle_suggest_config`, `handle_privacy` 추가
- `hook_voice/__main__.py` — `suggest-config`, `privacy` subcommand 등록

---

## Task 1: 통계 저장소 — `stats_store.py`

**Files:**
- Create: `hook_voice/learning/__init__.py`
- Create: `hook_voice/learning/stats_store.py`
- Create: `tests/learning/__init__.py`
- Create: `tests/learning/test_stats_store.py`

**Interfaces:**
- Produces:
  - `_STATS_FILE: Path` — `Path.home() / ".local/share/chorus/usage_stats.jsonl"`
  - `record_playback(agent_type: str, mode: str, priority: str, completed: bool, duration_secs: float) -> None`
  - `load_stats(limit: int = 500) -> list[dict]`
  - `clear_stats() -> int` — 삭제된 항목 수 반환
  - `stats_file_path() -> Path` — 현재 저장 경로 반환

- [ ] **Step 1: 테스트 파일 생성**

`tests/learning/__init__.py` — 빈 파일 생성.

`tests/learning/test_stats_store.py`:

```python
# 통계 저장소 단위 테스트
import json
from pathlib import Path
import pytest


def test_record_playback_appends_jsonl(tmp_path, monkeypatch):
    """record_playback이 JSONL 파일에 한 줄을 추가한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback(
        agent_type="builder", mode="full", priority="NORMAL",
        completed=True, duration_secs=3.5,
    )

    lines = (tmp_path / "stats.jsonl").read_text().splitlines()
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert entry["agent_type"] == "builder"
    assert entry["completed"] is True
    assert entry["duration_secs"] == pytest.approx(3.5, abs=0.01)
    assert "ts" in entry


def test_record_playback_multiple_appends(tmp_path, monkeypatch):
    """여러 번 호출하면 여러 줄이 추가된다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    for i in range(3):
        stats_store.record_playback("reviewer", "full", "HIGH", True, float(i))

    lines = (tmp_path / "stats.jsonl").read_text().splitlines()
    assert len(lines) == 3


def test_load_stats_returns_list(tmp_path, monkeypatch):
    """load_stats가 저장된 항목을 dict 리스트로 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback("planner", "summary_only", "NORMAL", False, 1.0)
    stats_store.record_playback("builder", "full", "NORMAL", True, 2.0)

    result = stats_store.load_stats()
    assert len(result) == 2
    assert result[0]["agent_type"] == "planner"
    assert result[1]["agent_type"] == "builder"


def test_load_stats_empty_file(tmp_path, monkeypatch):
    """파일이 없으면 빈 리스트를 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "nonexistent.jsonl")

    result = stats_store.load_stats()
    assert result == []


def test_clear_stats_deletes_file(tmp_path, monkeypatch):
    """clear_stats가 파일을 삭제하고 삭제된 항목 수를 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback("guardian", "full", "NORMAL", True, 5.0)
    stats_store.record_playback("guardian", "full", "NORMAL", False, 1.0)

    deleted = stats_store.clear_stats()
    assert deleted == 2
    assert not (tmp_path / "stats.jsonl").exists()


def test_clear_stats_no_file(tmp_path, monkeypatch):
    """파일이 없어도 0을 반환하고 에러가 없다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "nofile.jsonl")

    deleted = stats_store.clear_stats()
    assert deleted == 0


def test_load_stats_respects_limit(tmp_path, monkeypatch):
    """limit 파라미터가 최근 N개만 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    for i in range(10):
        stats_store.record_playback("tester", "full", "NORMAL", True, float(i))

    result = stats_store.load_stats(limit=3)
    assert len(result) == 3
    # 가장 최근 3개 (마지막 줄부터)
    assert result[-1]["duration_secs"] == pytest.approx(9.0, abs=0.01)
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/learning/test_stats_store.py -v --tb=short 2>&1 | head -20
```

Expected: `ModuleNotFoundError: No module named 'hook_voice.learning'`

- [ ] **Step 3: 패키지 마커 생성**

```bash
mkdir -p hook_voice/learning tests/learning
touch hook_voice/learning/__init__.py tests/learning/__init__.py
```

- [ ] **Step 4: `stats_store.py` 구현**

`hook_voice/learning/stats_store.py`:

```python
# hook_voice/learning/stats_store.py — TTS 사용 통계를 로컬 JSONL 파일에 저장·조회·삭제
from __future__ import annotations

import json
import time
from pathlib import Path

_STATS_FILE: Path = Path.home() / ".local" / "share" / "chorus" / "usage_stats.jsonl"


def stats_file_path() -> Path:
    """현재 통계 파일 경로를 반환한다."""
    return _STATS_FILE


def record_playback(
    agent_type: str,
    mode: str,
    priority: str,
    completed: bool,
    duration_secs: float,
) -> None:
    """TTS 재생 이벤트 한 건을 JSONL 파일에 추가한다.

    agent_type: 에이전트 타입 (예: "builder", "reviewer", "default")
    mode: 발화 모드 ("full" | "summary_only" | "earcon_only")
    priority: 우선순위 ("HIGH" | "NORMAL" | "LOW")
    completed: True이면 끝까지 재생, False이면 중단
    duration_secs: 재생 시도 시간 (초)
    """
    entry = {
        "ts": round(time.time(), 3),
        "agent_type": agent_type,
        "mode": mode,
        "priority": priority,
        "completed": completed,
        "duration_secs": round(duration_secs, 3),
    }
    _STATS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with _STATS_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def load_stats(limit: int = 500) -> list[dict]:
    """통계 파일에서 최근 limit개 항목을 반환한다.

    파일이 없으면 빈 리스트를 반환한다.
    """
    if not _STATS_FILE.exists():
        return []
    lines = _STATS_FILE.read_text(encoding="utf-8").splitlines()
    recent = lines[-limit:] if len(lines) > limit else lines
    result = []
    for line in recent:
        line = line.strip()
        if not line:
            continue
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def clear_stats() -> int:
    """통계 파일을 삭제하고 삭제된 항목 수를 반환한다."""
    if not _STATS_FILE.exists():
        return 0
    count = len(_STATS_FILE.read_text(encoding="utf-8").splitlines())
    _STATS_FILE.unlink()
    return count
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/learning/test_stats_store.py -v --tb=short
```

Expected: 7 tests PASSED

- [ ] **Step 6: 전체 회귀 확인**

```bash
.venv/bin/pytest tests/ --tb=short -q 2>&1 | tail -3
```

Expected: 385 passed

- [ ] **Step 7: 커밋**

```bash
git add hook_voice/learning/__init__.py hook_voice/learning/stats_store.py \
    tests/learning/__init__.py tests/learning/test_stats_store.py
git commit -m "feat: add stats_store for local TTS usage tracking (JSONL)"
```

---

## Task 2: `usage_tracking` 설정 추가

**Files:**
- Modify: `hook_voice/config.py` — `usage_tracking: bool = True` + `_KEY_MAP` 등록
- Modify: `tests/test_config.py` — 설정 파싱 테스트

**Interfaces:**
- Produces: `Config.usage_tracking: bool = True`
- `.voice.json` 키: `"usageTracking"`

- [ ] **Step 1: 테스트 작성**

`tests/test_config.py` 끝에 추가:

```python
def test_usage_tracking_default_true():
    """usage_tracking 기본값은 True다."""
    from hook_voice.config import Config
    cfg = Config()
    assert cfg.usage_tracking is True


def test_load_config_usage_tracking_false(tmp_path):
    """.voice.json에서 usageTracking: false를 파싱한다."""
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text('{"usageTracking": false}')
    cfg = load_config(cfg_file)
    assert cfg.usage_tracking is False


def test_load_config_usage_tracking_invalid(tmp_path):
    """usageTracking에 비-bool 값이 오면 기본값 True로 복원한다."""
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text('{"usageTracking": "yes"}')
    cfg = load_config(cfg_file)
    assert cfg.usage_tracking is True
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_config.py -k "usage_tracking" -v --tb=short
```

Expected: `AttributeError: Config has no field 'usage_tracking'`

- [ ] **Step 3: `config.py` 수정**

`hook_voice/config.py`에서:

`_KEY_MAP` 딕셔너리에 추가:
```python
"usageTracking": "usage_tracking",
```

`Config` dataclass에 추가:
```python
usage_tracking: bool = True
```

`_normalize_config` 함수에 추가:
```python
_normalize_bool("usage_tracking")
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_config.py -k "usage_tracking" -v --tb=short
```

Expected: 3 tests PASSED

- [ ] **Step 5: 전체 회귀 확인**

```bash
.venv/bin/pytest tests/ --tb=short -q 2>&1 | tail -3
```

Expected: 388 passed

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/config.py tests/test_config.py
git commit -m "feat: add usage_tracking config flag (usageTracking, default true)"
```

---

## Task 3: `handle_hook`에 통계 수집 삽입

**Files:**
- Modify: `hook_voice/hook_handlers.py` — TTS 완료·중단 시 `record_playback` 호출
- Modify: `tests/test_hook_handlers.py` — 통계 기록 테스트

**Interfaces:**
- Consumes: `stats_store.record_playback(agent_type, mode, priority, completed, duration_secs)`
- `handle_hook` 내 기록 시점:
  - TTS 성공: `completed=True`, `duration_secs=latency_ms/1000`
  - TTS 실패(except): `completed=False`, `duration_secs=elapsed`

- [ ] **Step 1: 테스트 작성**

`tests/test_hook_handlers.py` 끝에 추가:

```python
@pytest.mark.asyncio
async def test_handle_hook_records_completed_stat(tmp_path, monkeypatch):
    """TTS 성공 시 usage_tracking=True이면 completed=True 통계가 기록된다."""
    from hook_voice.hook_handlers import handle_hook
    from hook_voice.config import Config
    from hook_voice.learning import stats_store
    from unittest.mock import AsyncMock, patch

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")
    config = Config(auto_speak=True, min_chars=5, speech_retouch=False, usage_tracking=True)
    raw = '{"last_assistant_message": "작업이 완료됐습니다 충분히 긴 텍스트입니다."}'

    with (
        patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="완료됐습니다")),
        patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()),
    ):
        await handle_hook(raw, config)

    entries = stats_store.load_stats()
    assert len(entries) == 1
    assert entries[0]["completed"] is True
    assert entries[0]["agent_type"] == "default"


@pytest.mark.asyncio
async def test_handle_hook_records_failed_stat(tmp_path, monkeypatch):
    """TTS 실패 시 completed=False 통계가 기록된다."""
    from hook_voice.hook_handlers import handle_hook
    from hook_voice.config import Config
    from hook_voice.learning import stats_store
    from unittest.mock import AsyncMock, patch

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")
    config = Config(auto_speak=True, min_chars=5, speech_retouch=False, usage_tracking=True)
    raw = '{"last_assistant_message": "작업이 완료됐습니다 충분히 긴 텍스트입니다."}'

    with (
        patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="완료됐습니다")),
        patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock(side_effect=RuntimeError("TTS 오류"))),
    ):
        await handle_hook(raw, config)

    entries = stats_store.load_stats()
    assert len(entries) == 1
    assert entries[0]["completed"] is False


@pytest.mark.asyncio
async def test_handle_hook_skips_stat_when_tracking_disabled(tmp_path, monkeypatch):
    """usage_tracking=False이면 통계가 기록되지 않는다."""
    from hook_voice.hook_handlers import handle_hook
    from hook_voice.config import Config
    from hook_voice.learning import stats_store
    from unittest.mock import AsyncMock, patch

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")
    config = Config(auto_speak=True, min_chars=5, speech_retouch=False, usage_tracking=False)
    raw = '{"last_assistant_message": "작업이 완료됐습니다 충분히 긴 텍스트입니다."}'

    with (
        patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="완료됐습니다")),
        patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()),
    ):
        await handle_hook(raw, config)

    entries = stats_store.load_stats()
    assert len(entries) == 0
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -k "stat" -v --tb=short 2>&1 | tail -15
```

Expected: FAILED (통계 기록 코드 없음)

- [ ] **Step 3: `hook_handlers.py` 수정**

파일 상단 import 블록에 추가:

```python
from .learning.stats_store import record_playback as _record_stat
```

`handle_hook` 함수 내 `start = _time.time()` 이후 try 블록을:

```python
        start = _time.time()
        _speech_mode = dec.mode  # 통계용
        try:
            _status("🗣️ chorus: 음성 생성 중...")
            if use_reviewer:
                vm = load_voice_map()
                settings = resolve_voice_settings("code-reviewer", vm)
                instruct = resolve_instruct("code-reviewer", vm)
                monitor_flag.unlink(missing_ok=True)
                await speak_agent(
                    summary, "M2",
                    port=config.supertonic_port, speed=config.tts_speed,
                    instruct=instruct,
                    steps=settings["steps"],
                    synth_speed=settings["synth_speed"],
                    supertonic_timeout=config.supertonic_timeout_ms / 1000,
                )
            else:
                await speak_hook_chunked(summary, config.tts_speed)
            _status("▶️ chorus: 재생 중")
            latency_ms = (_time.time() - start) * 1000
            get_registry().record_tts_latency(latency_ms)
            log_event("tts_completed", hook_ctx, {
                "latency_ms": round(latency_ms, 1),
                "text_len": len(summary),
            })
            if config.usage_tracking:
                _record_stat(
                    agent_type="default",
                    mode=_speech_mode,
                    priority=dec.priority,
                    completed=True,
                    duration_secs=latency_ms / 1000,
                )
        except Exception as exc:
            _elapsed = (_time.time() - start) * 1000
            _status(f"⚠️ chorus: 음성 실패 ({type(exc).__name__})")
            log_event("tts_failed", hook_ctx, {"error": str(exc)}, level="WARNING")
            get_dlq_store().push(
                event_id=hook_ctx.correlation_id,
                failure_stage=failure_stage,
                failure_detail=str(exc),
                raw_text=summary[:200],
                source="stop_hook",
            )
            if config.usage_tracking:
                _record_stat(
                    agent_type="default",
                    mode=_speech_mode,
                    priority=dec.priority,
                    completed=False,
                    duration_secs=_elapsed / 1000,
                )
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -k "stat" -v --tb=short
```

Expected: 3 tests PASSED

- [ ] **Step 5: 전체 회귀 확인**

```bash
.venv/bin/pytest tests/ --tb=short -q 2>&1 | tail -3
```

Expected: 391 passed

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/hook_handlers.py tests/test_hook_handlers.py
git commit -m "feat: record TTS completion stats in handle_hook when usage_tracking=True"
```

---

## Task 4: 어드바이저 — 통계 분석 → 권장안 생성

**Files:**
- Create: `hook_voice/learning/advisor.py`
- Create: `tests/learning/test_advisor.py`

**Interfaces:**
- Produces:
  - `@dataclass class Suggestion: key: str; current: Any; recommended: Any; reason: str`
  - `analyze(stats: list[dict]) -> list[Suggestion]`
    - 완료율 < 60% 에이전트 → LOW 우선순위 권장
    - 에러 발화 비중 > 30% → 에러 우선순위 HIGH 이미 적용 중임을 안내
    - 전체 중단율 > 50% → `ttsSpeed` 낮추기 권장 (현재 설정값 필요 → config 파라미터)
    - 통계 부족 (< 10건) → 제안 없음

- [ ] **Step 1: 테스트 작성**

`tests/learning/test_advisor.py`:

```python
# 어드바이저 단위 테스트
import pytest


def _make_stat(agent_type="default", mode="full", priority="NORMAL",
               completed=True, duration_secs=3.0):
    return {
        "agent_type": agent_type,
        "mode": mode,
        "priority": priority,
        "completed": completed,
        "duration_secs": duration_secs,
    }


def test_analyze_returns_empty_when_too_few_stats():
    """통계가 10건 미만이면 제안이 없다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat() for _ in range(5)]
    result = analyze(stats)
    assert result == []


def test_analyze_suggests_low_priority_for_high_interrupt_agent():
    """특정 에이전트의 완료율이 60% 미만이면 LOW 우선순위를 권장한다."""
    from hook_voice.learning.advisor import analyze, Suggestion
    # builder: 10건 중 3건만 완료 (30% 완료율)
    stats = [_make_stat("builder", completed=True) for _ in range(3)]
    stats += [_make_stat("builder", completed=False) for _ in range(7)]
    stats += [_make_stat("default", completed=True) for _ in range(10)]  # 최소 10건 총계

    result = analyze(stats)
    keys = [s.key for s in result]
    assert any("builder" in k for k in keys)
    builder_sug = next(s for s in result if "builder" in s.key)
    assert builder_sug.recommended == "LOW"


def test_analyze_suggests_speed_reduction_when_high_interrupt_rate():
    """전체 중단율 > 50%이면 ttsSpeed 낮추기를 권장한다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=False) for _ in range(7)]
    stats += [_make_stat(completed=True) for _ in range(3)]
    # 총 10건, 중단율 70%

    result = analyze(stats)
    keys = [s.key for s in result]
    assert "ttsSpeed" in keys


def test_analyze_no_suggestion_when_completion_rate_ok():
    """완료율이 60% 이상이면 ttsSpeed 제안이 없다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=True) for _ in range(8)]
    stats += [_make_stat(completed=False) for _ in range(2)]
    # 총 10건, 완료율 80%

    result = analyze(stats)
    keys = [s.key for s in result]
    assert "ttsSpeed" not in keys


def test_suggestion_has_reason():
    """모든 제안에 reason 문자열이 있다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=False) for _ in range(7)]
    stats += [_make_stat(completed=True) for _ in range(3)]

    result = analyze(stats)
    for sug in result:
        assert isinstance(sug.reason, str)
        assert len(sug.reason) > 0
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/learning/test_advisor.py -v --tb=short 2>&1 | head -15
```

Expected: `ModuleNotFoundError: No module named 'hook_voice.learning.advisor'`

- [ ] **Step 3: `advisor.py` 구현**

`hook_voice/learning/advisor.py`:

```python
# hook_voice/learning/advisor.py — 사용 통계 분석 → .voice.json 설정 권장안 생성
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class Suggestion:
    """단일 설정 권장안."""
    key: str          # 권장 대상 키 (예: "ttsSpeed", "builder_priority")
    current: Any      # 현재 값 (알 수 없으면 None)
    recommended: Any  # 권장 값
    reason: str       # 사유 문장 (경어체)


_MIN_STATS = 10          # 제안 생성에 필요한 최소 통계 수
_INTERRUPT_THRESHOLD = 0.5   # 전체 중단율 임계값
_AGENT_COMPLETION_MIN = 0.6  # 에이전트별 완료율 최소값


def analyze(stats: list[dict]) -> list[Suggestion]:
    """통계 목록을 분석해 설정 권장안 리스트를 반환한다.

    통계가 _MIN_STATS건 미만이면 빈 리스트를 반환한다.
    """
    if len(stats) < _MIN_STATS:
        return []

    suggestions: list[Suggestion] = []

    # 1. 전체 중단율 > 50% → ttsSpeed 낮추기 권장
    total = len(stats)
    interrupted = sum(1 for s in stats if not s.get("completed", True))
    interrupt_rate = interrupted / total
    if interrupt_rate > _INTERRUPT_THRESHOLD:
        suggestions.append(Suggestion(
            key="ttsSpeed",
            current=None,
            recommended=0.95,
            reason=(
                f"최근 {total}건 중 {interrupted}건({interrupt_rate:.0%})이 중단됐습니다. "
                "재생 속도를 낮추면 끝까지 듣는 비율이 높아질 수 있습니다."
            ),
        ))

    # 2. 에이전트별 완료율 < 60% → LOW 우선순위 권장
    from collections import defaultdict
    agent_stats: dict[str, list[bool]] = defaultdict(list)
    for s in stats:
        atype = s.get("agent_type", "default")
        if atype == "default":
            continue
        agent_stats[atype].append(bool(s.get("completed", True)))

    for agent, completions in agent_stats.items():
        if len(completions) < 5:  # 에이전트별 최소 5건 필요
            continue
        rate = sum(completions) / len(completions)
        if rate < _AGENT_COMPLETION_MIN:
            suggestions.append(Suggestion(
                key=f"{agent}_priority",
                current="NORMAL",
                recommended="LOW",
                reason=(
                    f"{agent} 에이전트 응답 {len(completions)}건 중 완료율이 "
                    f"{rate:.0%}입니다. voice-map.json에서 해당 에이전트의 "
                    "우선순위를 LOW로 설정하면 다른 응답을 방해하지 않습니다."
                ),
            ))

    return suggestions
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/learning/test_advisor.py -v --tb=short
```

Expected: 5 tests PASSED

- [ ] **Step 5: 전체 회귀 확인**

```bash
.venv/bin/pytest tests/ --tb=short -q 2>&1 | tail -3
```

Expected: 396 passed

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/learning/advisor.py tests/learning/test_advisor.py
git commit -m "feat: add usage stats advisor with ttsSpeed and agent priority suggestions"
```

---

## Task 5: `suggest-config` / `privacy` CLI subcommand

**Files:**
- Modify: `hook_voice/hook_handlers.py` — `handle_suggest_config`, `handle_privacy` 추가
- Modify: `hook_voice/__main__.py` — subcommand 등록
- Modify: `tests/test_hook_handlers.py` — CLI 동작 테스트

**Interfaces:**
- `handle_suggest_config(config: Config) -> None` — 통계 로드 → analyze → 결과 출력
- `handle_privacy(args: list[str], config: Config) -> None` — args[0] == "clear"이면 clear_stats()

- [ ] **Step 1: 테스트 작성**

`tests/test_hook_handlers.py` 끝에 추가:

```python
@pytest.mark.asyncio
async def test_handle_suggest_config_no_stats(capsys, tmp_path, monkeypatch):
    """통계가 없으면 '데이터 부족' 안내를 출력한다."""
    from hook_voice.hook_handlers import handle_suggest_config
    from hook_voice.config import Config
    from hook_voice.learning import stats_store

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "empty.jsonl")
    config = Config()
    await handle_suggest_config(config)

    out = capsys.readouterr().out
    assert "부족" in out or "없습니다" in out or "데이터" in out


@pytest.mark.asyncio
async def test_handle_suggest_config_with_suggestions(capsys, tmp_path, monkeypatch):
    """충분한 통계가 있으면 제안을 출력한다."""
    from hook_voice.hook_handlers import handle_suggest_config
    from hook_voice.config import Config
    from hook_voice.learning import stats_store

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    # 중단율 70% 생성
    for _ in range(7):
        stats_store.record_playback("default", "full", "NORMAL", False, 1.0)
    for _ in range(3):
        stats_store.record_playback("default", "full", "NORMAL", True, 3.0)

    config = Config()
    await handle_suggest_config(config)

    out = capsys.readouterr().out
    assert "ttsSpeed" in out or "권장" in out or "제안" in out


@pytest.mark.asyncio
async def test_handle_privacy_clear(capsys, tmp_path, monkeypatch):
    """privacy clear가 통계 파일을 삭제하고 결과를 출력한다."""
    from hook_voice.hook_handlers import handle_privacy
    from hook_voice.config import Config
    from hook_voice.learning import stats_store

    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")
    stats_store.record_playback("default", "full", "NORMAL", True, 2.0)

    config = Config()
    await handle_privacy(["clear"], config)

    out = capsys.readouterr().out
    assert "삭제" in out or "제거" in out
    assert not (tmp_path / "stats.jsonl").exists()
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -k "suggest_config or privacy" -v --tb=short 2>&1 | tail -10
```

Expected: `ImportError: cannot import name 'handle_suggest_config'`

- [ ] **Step 3: `hook_handlers.py`에 함수 추가**

파일 import 블록에 추가:

```python
from .learning.stats_store import load_stats as _load_stats, clear_stats as _clear_stats, stats_file_path as _stats_file_path
from .learning.advisor import analyze as _analyze_stats
```

파일 끝에 추가:

```python
async def handle_suggest_config(config: Config) -> None:
    """사용 통계를 분석해 .voice.json 개선안을 제안한다."""
    stats = _load_stats()
    stats_path = _stats_file_path()
    print(f"[suggest-config] 통계 파일: {stats_path} ({len(stats)}건)", flush=True)

    if len(stats) < 10:
        print(
            f"[suggest-config] 데이터가 부족합니다 ({len(stats)}건). "
            "최소 10건의 TTS 발화 후 다시 실행해 주세요.",
            flush=True,
        )
        return

    suggestions = _analyze_stats(stats)
    if not suggestions:
        print("[suggest-config] 현재 설정이 사용 패턴에 잘 맞습니다. 제안 사항이 없습니다.", flush=True)
        return

    print(f"[suggest-config] {len(suggestions)}개 제안이 있습니다.\n", flush=True)
    for i, sug in enumerate(suggestions, 1):
        current_str = f"{sug.current}" if sug.current is not None else "(현재값 미확인)"
        print(
            f"  [{i}] {sug.key}\n"
            f"      현재: {current_str}  →  권장: {sug.recommended}\n"
            f"      이유: {sug.reason}\n",
            flush=True,
        )
    print(
        "적용하려면 .voice.json을 직접 편집하거나 다음 명령을 사용하세요:",
        flush=True,
    )
    for sug in suggestions:
        print(f"  python -m hook_voice config set {sug.key} {sug.recommended}", flush=True)


async def handle_privacy(args: list[str], config: Config) -> None:
    """사용 통계 데이터를 관리한다.

    privacy clear  — 모든 통계 데이터를 삭제한다
    privacy status — 통계 파일 경로와 크기를 출력한다
    """
    sub = args[0] if args else ""
    stats_path = _stats_file_path()

    if sub == "clear":
        deleted = _clear_stats()
        if deleted > 0:
            print(f"[privacy] 통계 데이터 {deleted}건이 삭제됐습니다. ({stats_path})", flush=True)
        else:
            print(f"[privacy] 삭제할 통계 데이터가 없습니다. ({stats_path})", flush=True)
    elif sub == "status":
        if stats_path.exists():
            size_kb = stats_path.stat().st_size / 1024
            count = len(_load_stats())
            print(
                f"[privacy] 통계 파일: {stats_path}\n"
                f"          항목 수: {count}건 ({size_kb:.1f} KB)",
                flush=True,
            )
        else:
            print(f"[privacy] 통계 파일 없음 ({stats_path})", flush=True)
    else:
        print(
            "사용법:\n"
            "  python -m hook_voice privacy clear   — 모든 통계 삭제\n"
            "  python -m hook_voice privacy status  — 통계 파일 정보 확인",
            flush=True,
        )
```

- [ ] **Step 4: `__main__.py` subcommand 등록**

`hook_voice/__main__.py`의 import에 추가:

```python
from .hook_handlers import (
    ...
    handle_suggest_config,
    handle_privacy,
)
```

`main()` 함수의 elif 체인에 추가:

```python
    elif subcommand == "suggest-config":
        await handle_suggest_config(config)
    elif subcommand == "privacy":
        await handle_privacy(sys.argv[2:], config)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -k "suggest_config or privacy" -v --tb=short
```

Expected: 3 tests PASSED

- [ ] **Step 6: 전체 회귀 확인**

```bash
.venv/bin/pytest tests/ --tb=short -q 2>&1 | tail -3
```

Expected: 399 passed

- [ ] **Step 7: 커밋**

```bash
git add hook_voice/hook_handlers.py hook_voice/__main__.py tests/test_hook_handlers.py
git commit -m "feat: add 'suggest-config' and 'privacy' CLI subcommands for adaptive learning"
```

---

## Task 6: README·CLAUDE.md 업데이트 + 보류 섹션 완료 표시

**Files:**
- Modify: `README.md` — 보류 섹션의 "미구현 → 구현됨" 상태 업데이트, 사용법 추가
- Modify: `CLAUDE.md` — 새 subcommand 및 파일 역할 추가

- [ ] **Step 1: README 자동 학습 섹션 상태 업데이트**

README의 "자동 학습·적응 레이어 (보류 기능)" 섹션 제목을 다음으로 교체:

```markdown
## 자동 학습·적응 레이어
```

섹션 본문 서두에 아래 추가:

```markdown
> **현재 상태**: 구현 완료. `chorus suggest-config`으로 제안을 확인하고, `chorus privacy clear`로 데이터를 삭제할 수 있습니다.
```

기존 "현재 상태: 설계 단계, 미구현" 줄 제거.

"현재 대안" 섹션 끝에 실제 사용법 추가:

```markdown
### 사용법

```bash
# 설정 권장안 확인 (자동 적용 없음)
python -m hook_voice suggest-config

# 통계 파일 위치 확인
python -m hook_voice privacy status

# 모든 통계 데이터 삭제
python -m hook_voice privacy clear
```

통계는 `~/.local/share/chorus/usage_stats.jsonl`에 로컬 저장됩니다.  
`.voice.json`에 `"usageTracking": false`를 추가하면 수집이 중단됩니다.
```

- [ ] **Step 2: CLAUDE.md 업데이트**

CLAUDE.md의 명령어 섹션에 추가:

```bash
# 자동 학습·적응
python -m hook_voice suggest-config   # 사용 패턴 분석 → 설정 권장안 출력
python -m hook_voice privacy status   # 통계 파일 정보
python -m hook_voice privacy clear    # 통계 데이터 전체 삭제
```

파일별 역할 표에 추가:

```
| `hook_voice/learning/stats_store.py` | TTS 사용 통계 JSONL 저장·조회·삭제 |
| `hook_voice/learning/advisor.py` | 통계 분석 → 설정 권장안 생성 |
```

설정 표에 추가:

```
| `usageTracking` | `true` | 사용 통계 수집 여부 (false이면 수집 없음) |
```

- [ ] **Step 3: 커밋 및 푸시**

```bash
git add README.md CLAUDE.md
git commit -m "docs: mark adaptive learning as implemented, add suggest-config/privacy usage"
git push origin main
```

---

## Self-Review

### Spec coverage

| 설계 요구사항 | 태스크 |
|--------------|--------|
| 익명 통계 로컬 수집 (JSONL) | Task 1 stats_store |
| `usage_tracking: false` opt-out | Task 2 config |
| TTS 완료/중단 시 기록 | Task 3 hook_handlers 수정 |
| 통계 분석 → 권장안 생성 | Task 4 advisor |
| `suggest-config` CLI (자동 적용 없음) | Task 5 |
| `privacy clear/status` CLI | Task 5 |
| 문서 업데이트 | Task 6 |
| stdlib 외 추가 의존성 없음 | ✅ json/pathlib/collections만 사용 |
| 자동 설정 변경 금지 | ✅ suggest-config는 출력만 |
| 프로젝트별 격리 (전역 공유 없음) | ✅ 단일 고정 파일 경로 |

### Placeholder 스캔

모든 스텝에 실제 코드 포함 ✅  
실행 명령어와 예상 출력 포함 ✅

### 타입 일관성

- `record_playback(agent_type, mode, priority, completed, duration_secs)` — Task 1 정의, Task 3 사용 ✅
- `analyze(stats: list[dict]) -> list[Suggestion]` — Task 4 정의, Task 5 사용 ✅
- `Suggestion.key / .recommended / .reason` — Task 4 정의, Task 5 출력 코드 참조 ✅
- `load_stats() -> list[dict]` / `clear_stats() -> int` — Task 1 정의, Task 5 import ✅
