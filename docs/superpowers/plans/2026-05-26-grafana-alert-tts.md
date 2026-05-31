# Grafana Alert TTS 발화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HMG 사내 Grafana 알럿을 30초 폴링으로 수신하고, LLM 분석 요약을 TTS로 발화한다.

**Architecture:** `tts_server/supervisor.py`의 `asyncio.gather()`에 `GrafanaPoller.run()` 코루틴을 추가한다. 폴러는 Grafana Alertmanager API를 주기적으로 폴링하고, 상태 변화(Firing/Resolved)를 감지해 HMG Hub LLM으로 분석 후 `speak_hook()`으로 발화한다. 기존 TTS spool 직렬화 인프라를 변경 없이 재사용한다.

**Tech Stack:** Python asyncio, httpx(verify=False), Grafana Alertmanager API v2, HMG Hub LLM (`gpt-5.4`), EdgeTTS spool

---

## 파일 구성

| 파일 | 변경 종류 | 역할 |
|------|------|------|
| `hook_voice/config.py` | 수정 | GrafanaConfig dataclass + load_config 중첩 파싱 |
| `hook_voice/grafana_poller.py` | **신규** | AlertChange, poll_once, analyze_alert, GrafanaPoller |
| `tts_server/supervisor.py` | 수정 | asyncio.gather에 poller.run() 추가 |
| `hook_voice/hook_handlers.py` | 수정 | handle_grafana() — CLI 서브커맨드 핸들러 |
| `hook_voice/__main__.py` | 수정 | `grafana` 서브커맨드 라우팅 |
| `tests/test_grafana_poller.py` | **신규** | 전체 단위 테스트 |
| `tests/test_grafana_config.py` | **신규** | config 파싱 테스트 |

---

## Task 1: GrafanaConfig 설정 필드 추가

**Files:**
- Modify: `hook_voice/config.py`
- Create: `tests/test_grafana_config.py`

- [ ] **Step 1: 테스트 작성**

```python
# tests/test_grafana_config.py
import json
import pytest
from hook_voice.config import Config, GrafanaConfig, load_config


def test_grafana_config_defaults():
    config = Config()
    assert config.grafana.enabled is False
    assert config.grafana.url == ""
    assert config.grafana.token == ""
    assert config.grafana.interval == 30
    assert config.grafana.alerts == []


def test_load_config_grafana_section(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({
        "grafana": {
            "enabled": True,
            "url": "http://grafana.internal:3000",
            "token": "glsa_test",
            "interval": 60,
            "alerts": ["Kafka Consumer Lag", "Spark Job Failed"],
        }
    }), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is True
    assert config.grafana.url == "http://grafana.internal:3000"
    assert config.grafana.token == "glsa_test"
    assert config.grafana.interval == 60
    assert config.grafana.alerts == ["Kafka Consumer Lag", "Spark Job Failed"]


def test_load_config_grafana_partial(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({"grafana": {"enabled": True}}), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is True
    assert config.grafana.interval == 30  # 기본값 유지


def test_load_config_without_grafana(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({"voice": "Sohee"}), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is False
    assert config.voice == "Sohee"
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd /Users/hmc7102758/Develop/Workspaces/chorus
.venv/bin/pytest tests/test_grafana_config.py -v
```

Expected: `FAILED — cannot import name 'GrafanaConfig'`

- [ ] **Step 3: config.py에 GrafanaConfig 추가**

```python
# hook_voice/config.py
# 사용자 설정 파일 로더 및 기본값 관리
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

_logger = logging.getLogger(__name__)

_DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / ".voice-persona.json"

_KEY_MAP = {
    "autoSpeak": "auto_speak",
    "minChars": "min_chars",
    "voice": "voice",
    "summaryModel": "summary_model",
    "ttsSpeed": "tts_speed",
    "ttsInstruct": "tts_instruct",
    "skillCooldownMinutes": "skill_cooldown_minutes",
    "supertonicPort": "supertonic_port",
    "edgeTimeoutMs": "edge_timeout_ms",
    "supertonicTimeoutMs": "supertonic_timeout_ms",
}


@dataclass
class GrafanaConfig:
    enabled: bool = False
    url: str = ""
    token: str = ""
    interval: int = 30
    alerts: list = field(default_factory=list)


@dataclass
class Config:
    auto_speak: bool = True
    min_chars: int = 50
    voice: str = "Sohee"
    summary_model: str = "gpt-5.4"
    tts_speed: float = 1.1
    tts_instruct: str = "밝고 활기차게 말해주세요"
    skill_cooldown_minutes: int = 30
    supertonic_port: int = 7788
    edge_timeout_ms: int = 10000
    supertonic_timeout_ms: int = 20000
    grafana: GrafanaConfig = field(default_factory=GrafanaConfig)


def load_config(path: Path | None = None) -> Config:
    target = path or _DEFAULT_CONFIG_PATH
    if not target.exists():
        return Config()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        kwargs = {py_k: data[json_k] for json_k, py_k in _KEY_MAP.items() if json_k in data}
        if "grafana" in data:
            g = data["grafana"]
            kwargs["grafana"] = GrafanaConfig(
                enabled=g.get("enabled", False),
                url=g.get("url", ""),
                token=g.get("token", ""),
                interval=g.get("interval", 30),
                alerts=g.get("alerts", []),
            )
        return Config(**kwargs)
    except json.JSONDecodeError as e:
        _logger.warning("voice-persona.json 파싱 실패, 기본값 사용: %s", e)
        return Config()
    except Exception as e:
        _logger.warning("voice-persona.json 로드 실패, 기본값 사용: %s", e)
        return Config()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_grafana_config.py -v
```

Expected: `4 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/config.py tests/test_grafana_config.py
git commit -m "feat: GrafanaConfig 설정 필드 추가"
```

---

## Task 2: AlertChange dataclass + poll_once + _detect_changes 구현

**Files:**
- Create: `hook_voice/grafana_poller.py`
- Modify: `tests/test_grafana_poller.py`

Grafana Alertmanager API v2 응답 형식:
```json
[
  {
    "fingerprint": "abc123",
    "labels": {"alertname": "KafkaLag", "severity": "critical"},
    "annotations": {"summary": "Kafka lag exceeded 10000", "description": "Consumer group lag"},
    "status": {"state": "active", "inhibitedBy": [], "silencedBy": []},
    "startsAt": "2026-05-26T10:00:00.000Z",
    "endsAt": "0001-01-01T00:00:00Z"
  }
]
```

`status.state == "active"` → Firing 중. 이전 사이클 대비 신규 fingerprint = Firing 이벤트, 사라진 fingerprint = Resolved 이벤트.

- [ ] **Step 1: 테스트 작성**

```python
# tests/test_grafana_poller.py
import asyncio
import pytest
from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch, MagicMock

from hook_voice.config import Config, GrafanaConfig
from hook_voice.grafana_poller import AlertChange, GrafanaPoller, _detect_changes


SAMPLE_ALERT = {
    "fingerprint": "fp001",
    "labels": {"alertname": "KafkaLag", "severity": "critical"},
    "annotations": {"summary": "Kafka lag exceeded 10000", "description": "Consumer lag high"},
    "status": {"state": "active"},
    "startsAt": "2026-05-26T10:00:00.000Z",
    "endsAt": "0001-01-01T00:00:00Z",
}

SAMPLE_ALERT_2 = {
    "fingerprint": "fp002",
    "labels": {"alertname": "SparkFailed", "severity": "warning"},
    "annotations": {"summary": "Spark job failed"},
    "status": {"state": "active"},
    "startsAt": "2026-05-26T10:01:00.000Z",
    "endsAt": "0001-01-01T00:00:00Z",
}


def _make_config(alerts=None):
    return Config(
        grafana=GrafanaConfig(
            enabled=True,
            url="http://grafana.internal:3000",
            token="glsa_test",
            interval=30,
            alerts=alerts or ["KafkaLag"],
        )
    )


async def test_poll_once_returns_active_alerts():
    config = _make_config()
    poller = GrafanaPoller(config)
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json = MagicMock(return_value=[SAMPLE_ALERT])

    with patch("hook_voice.grafana_poller.httpx.AsyncClient") as mock_client_cls:
        mock_client = AsyncMock()
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client_cls.return_value = mock_client

        result = await poller.poll_once()

    assert "fp001" in result
    assert result["fp001"]["labels"]["alertname"] == "KafkaLag"


async def test_poll_once_returns_empty_on_error():
    config = _make_config()
    poller = GrafanaPoller(config)

    with patch("hook_voice.grafana_poller.httpx.AsyncClient") as mock_client_cls:
        mock_client = AsyncMock()
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)
        mock_client.get = AsyncMock(side_effect=Exception("network error"))
        mock_client_cls.return_value = mock_client

        result = await poller.poll_once()

    assert result == {}


def test_detect_changes_new_firing():
    prev = {}
    curr = {"fp001": SAMPLE_ALERT}
    changes = _detect_changes(prev, curr, watched=["KafkaLag"])
    assert len(changes) == 1
    assert changes[0].status == "firing"
    assert changes[0].name == "KafkaLag"


def test_detect_changes_resolved():
    prev = {"fp001": SAMPLE_ALERT}
    curr = {}
    changes = _detect_changes(prev, curr, watched=["KafkaLag"])
    assert len(changes) == 1
    assert changes[0].status == "resolved"
    assert changes[0].duration is not None


def test_detect_changes_no_change():
    prev = {"fp001": SAMPLE_ALERT}
    curr = {"fp001": SAMPLE_ALERT}
    changes = _detect_changes(prev, curr, watched=["KafkaLag"])
    assert changes == []


def test_detect_changes_filters_unwatched():
    prev = {}
    curr = {"fp002": SAMPLE_ALERT_2}
    changes = _detect_changes(prev, curr, watched=["KafkaLag"])
    assert changes == []


def test_detect_changes_multiple():
    prev = {"fp001": SAMPLE_ALERT}
    curr = {"fp002": SAMPLE_ALERT_2}
    changes = _detect_changes(prev, curr, watched=["KafkaLag", "SparkFailed"])
    statuses = {c.status for c in changes}
    assert "firing" in statuses   # fp002 신규
    assert "resolved" in statuses  # fp001 사라짐
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py -v
```

Expected: `ERROR — cannot import name 'GrafanaPoller'`

- [ ] **Step 3: grafana_poller.py 기본 구조 구현**

```python
# hook_voice/grafana_poller.py
# Grafana Alertmanager API 폴링 — 상태 변화 감지 및 TTS 발화
import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from typing import Literal

import httpx

from .config import Config

_log = logging.getLogger(__name__)

_ZERO_TIME = "0001-01-01T00:00:00Z"


@dataclass
class AlertChange:
    name: str
    status: Literal["firing", "resolved"]
    labels: dict
    annotations: dict
    value: str
    started_at: datetime
    duration: timedelta | None = None


def _parse_dt(s: str) -> datetime:
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return datetime.now(timezone.utc)


def _detect_changes(
    prev: dict,
    curr: dict,
    watched: list[str],
) -> list[AlertChange]:
    changes: list[AlertChange] = []
    watched_set = set(watched)

    for fp, alert in curr.items():
        name = alert["labels"].get("alertname", "")
        if name not in watched_set:
            continue
        if fp not in prev:
            changes.append(AlertChange(
                name=name,
                status="firing",
                labels=alert["labels"],
                annotations=alert.get("annotations", {}),
                value=alert.get("value", ""),
                started_at=_parse_dt(alert.get("startsAt", _ZERO_TIME)),
            ))

    for fp, alert in prev.items():
        name = alert["labels"].get("alertname", "")
        if name not in watched_set:
            continue
        if fp not in curr:
            started = _parse_dt(alert.get("startsAt", _ZERO_TIME))
            duration = datetime.now(timezone.utc) - started
            changes.append(AlertChange(
                name=name,
                status="resolved",
                labels=alert["labels"],
                annotations=alert.get("annotations", {}),
                value=alert.get("value", ""),
                started_at=started,
                duration=duration,
            ))

    return changes


class GrafanaPoller:
    def __init__(self, config: Config) -> None:
        self._config = config

    async def poll_once(self) -> dict:
        g = self._config.grafana
        url = f"{g.url.rstrip('/')}/api/alertmanager/grafana/api/v2/alerts"
        headers = {"Authorization": f"Bearer {g.token}"}
        try:
            async with httpx.AsyncClient(verify=False, timeout=10.0) as client:
                resp = await client.get(url, headers=headers)
                if resp.status_code in (401, 403):
                    raise PermissionError(f"Grafana 인증 실패 (HTTP {resp.status_code})")
                resp.raise_for_status()
                alerts = resp.json()
                return {
                    a["fingerprint"]: a
                    for a in alerts
                    if a.get("status", {}).get("state") == "active"
                }
        except PermissionError:
            raise
        except Exception as e:
            _log.warning("[Grafana] 폴링 실패: %s", e)
            return {}

    async def analyze_alert(self, change: AlertChange) -> str:
        """LLM으로 알럿 분석 — 실패 시 규칙 기반 폴백."""
        return f"{change.name} 알럿이 발생했습니다."

    async def run(self, shutdown: asyncio.Event) -> None:
        """supervisor에서 호출하는 폴링 루프."""
        pass
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py::test_poll_once_returns_active_alerts \
  tests/test_grafana_poller.py::test_poll_once_returns_empty_on_error \
  tests/test_grafana_poller.py::test_detect_changes_new_firing \
  tests/test_grafana_poller.py::test_detect_changes_resolved \
  tests/test_grafana_poller.py::test_detect_changes_no_change \
  tests/test_grafana_poller.py::test_detect_changes_filters_unwatched \
  tests/test_grafana_poller.py::test_detect_changes_multiple -v
```

Expected: `7 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/grafana_poller.py tests/test_grafana_poller.py
git commit -m "feat: AlertChange dataclass + poll_once + _detect_changes 구현"
```

---

## Task 3: analyze_alert LLM 분석 구현

**Files:**
- Modify: `hook_voice/grafana_poller.py`
- Modify: `tests/test_grafana_poller.py`

- [ ] **Step 1: 테스트 추가**

`tests/test_grafana_poller.py` 끝에 다음을 추가:

```python
async def test_analyze_alert_returns_llm_summary():
    config = _make_config()
    poller = GrafanaPoller(config)
    change = AlertChange(
        name="KafkaLag",
        status="firing",
        labels={"alertname": "KafkaLag", "severity": "critical"},
        annotations={"summary": "lag exceeded 10000"},
        value="10500",
        started_at=datetime(2026, 5, 26, 10, 0, tzinfo=timezone.utc),
    )
    with patch("hook_voice.grafana_poller.chat_completion", new=AsyncMock(return_value="Kafka 컨슈머 처리 지연입니다.")):
        result = await poller.analyze_alert(change)
    assert result == "Kafka 컨슈머 처리 지연입니다."


async def test_analyze_alert_fallback_on_empty_llm():
    config = _make_config()
    poller = GrafanaPoller(config)
    change = AlertChange(
        name="KafkaLag",
        status="firing",
        labels={"alertname": "KafkaLag"},
        annotations={},
        value="",
        started_at=datetime(2026, 5, 26, 10, 0, tzinfo=timezone.utc),
    )
    with patch("hook_voice.grafana_poller.chat_completion", new=AsyncMock(return_value="")):
        result = await poller.analyze_alert(change)
    assert "KafkaLag" in result
    assert len(result) > 0


async def test_analyze_alert_resolved_no_llm():
    config = _make_config()
    poller = GrafanaPoller(config)
    change = AlertChange(
        name="KafkaLag",
        status="resolved",
        labels={"alertname": "KafkaLag"},
        annotations={},
        value="",
        started_at=datetime(2026, 5, 26, 10, 0, tzinfo=timezone.utc),
        duration=timedelta(minutes=5),
    )
    with patch("hook_voice.grafana_poller.chat_completion", new=AsyncMock()) as mock_llm:
        result = await poller.analyze_alert(change)
        mock_llm.assert_not_called()
    assert "해소" in result
    assert "5분" in result
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py::test_analyze_alert_returns_llm_summary \
  tests/test_grafana_poller.py::test_analyze_alert_fallback_on_empty_llm \
  tests/test_grafana_poller.py::test_analyze_alert_resolved_no_llm -v
```

Expected: `FAILED — chat_completion not imported`

- [ ] **Step 3: analyze_alert 구현 (grafana_poller.py 상단에 import 추가 후 메서드 교체)**

`grafana_poller.py` 상단 import에 추가:
```python
from .llm_client import chat_completion
```

`analyze_alert` 메서드를 교체:
```python
async def analyze_alert(self, change: AlertChange) -> str:
    """LLM으로 알럿 분석 — 실패 시 규칙 기반 폴백."""
    if change.status == "resolved":
        mins = int(change.duration.total_seconds() // 60) if change.duration else 0
        return f"{change.name} 알럿이 해소되었습니다. {mins}분 만에 복구됐습니다."

    summary = change.annotations.get("summary") \
        or change.annotations.get("description") \
        or "(설명 없음)"
    prompt = (
        f"다음 Grafana 알럿 정보를 보고 원인과 대응 방향을 2-3문장으로 간결하게 설명하세요.\n"
        f"알럿명: {change.name}\n"
        f"심각도: {change.labels.get('severity', '알 수 없음')}\n"
        f"현재값: {change.value or '알 수 없음'}\n"
        f"설명: {summary}"
    )
    result = await chat_completion(
        messages=[{"role": "user", "content": prompt}],
        model=self._config.summary_model,
    )
    return result if result else f"{change.name} 알럿이 발생했습니다."
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py -v
```

Expected: `10 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/grafana_poller.py tests/test_grafana_poller.py
git commit -m "feat: analyze_alert — LLM 분석 + resolved 규칙 기반 텍스트"
```

---

## Task 4: GrafanaPoller.run() + burst 처리 구현

**Files:**
- Modify: `hook_voice/grafana_poller.py`
- Modify: `tests/test_grafana_poller.py`

- [ ] **Step 1: 테스트 추가**

`tests/test_grafana_poller.py` 끝에 추가:

```python
async def test_run_first_cycle_no_speak():
    """첫 사이클은 snapshot만 수집하고 발화하지 않는다."""
    config = _make_config(alerts=["KafkaLag"])
    poller = GrafanaPoller(config)

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json = MagicMock(return_value=[SAMPLE_ALERT])

    shutdown = asyncio.Event()

    async def fake_poll():
        shutdown.set()
        return {"fp001": SAMPLE_ALERT}

    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak:
        await poller.run(shutdown)
        mock_speak.assert_not_called()


async def test_run_fires_on_second_cycle():
    """두 번째 사이클에서 새 알럿 감지 시 발화한다."""
    config = _make_config(alerts=["KafkaLag"])
    poller = GrafanaPoller(config)

    call_count = 0

    async def fake_poll():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return {}
        shutdown.set()
        return {"fp001": SAMPLE_ALERT}

    shutdown = asyncio.Event()
    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak, \
         patch.object(poller, "analyze_alert", new=AsyncMock(return_value="Kafka 알럿입니다.")):
        await poller.run(shutdown)
        mock_speak.assert_called_once()


async def test_run_burst_over_3_alerts():
    """3개 초과 알럿은 묶음 발화한다."""
    config = _make_config(alerts=["A1", "A2", "A3", "A4"])
    poller = GrafanaPoller(config)

    alerts = [
        {**SAMPLE_ALERT, "fingerprint": f"fp{i}",
         "labels": {"alertname": f"A{i}", "severity": "critical"}}
        for i in range(1, 5)
    ]

    call_count = 0

    async def fake_poll():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return {}
        shutdown.set()
        return {a["fingerprint"]: a for a in alerts}

    shutdown = asyncio.Event()
    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak:
        await poller.run(shutdown)
        assert mock_speak.call_count == 1
        text = mock_speak.call_args[0][0]
        assert "4개" in text
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py::test_run_first_cycle_no_speak \
  tests/test_grafana_poller.py::test_run_fires_on_second_cycle \
  tests/test_grafana_poller.py::test_run_burst_over_3_alerts -v
```

Expected: `FAILED` (run()이 `pass`이므로)

- [ ] **Step 3: run() 구현 (grafana_poller.py에 import 추가 및 run 메서드 교체)**

파일 상단 import에 추가:
```python
from .player import speak_hook
```

`GrafanaPoller.run()` 메서드를 교체:
```python
async def run(self, shutdown: asyncio.Event) -> None:
    """supervisor에서 호출하는 폴링 루프."""
    g = self._config.grafana
    if not g.enabled or not g.url or not g.token:
        _log.info("[Grafana] 폴러 비활성화 (enabled=False 또는 url/token 미설정)")
        await shutdown.wait()
        return

    _log.info("[Grafana] 폴링 시작 (interval=%ds, alerts=%s)", g.interval, g.alerts)
    prev_snapshot: dict = {}
    first_run = True

    while not shutdown.is_set():
        try:
            curr = await self.poll_once()
        except PermissionError as e:
            _log.error("[Grafana] %s — 폴러를 비활성화합니다.", e)
            await speak_hook(
                f"Grafana 인증에 실패했습니다. 토큰을 확인해 주세요.",
                self._config.voice,
                self._config.tts_speed,
            )
            break

        if first_run:
            prev_snapshot = curr
            first_run = False
            _log.info("[Grafana] 첫 폴링 완료 — snapshot 수집 (발화 없음)")
        else:
            changes = _detect_changes(prev_snapshot, curr, g.alerts)
            if changes:
                await self._handle_changes(changes)
            prev_snapshot = curr

        try:
            await asyncio.wait_for(shutdown.wait(), timeout=float(g.interval))
        except asyncio.TimeoutError:
            pass

async def _handle_changes(self, changes: list[AlertChange]) -> None:
    """알럿 변화를 TTS로 발화. 3개 초과 시 묶음 요약."""
    if len(changes) > 3:
        firing = sum(1 for c in changes if c.status == "firing")
        resolved = sum(1 for c in changes if c.status == "resolved")
        parts = []
        if firing:
            parts.append(f"발생 {firing}개")
        if resolved:
            parts.append(f"해소 {resolved}개")
        text = f"{len(changes)}개 알럿 상태가 변경됐습니다. {', '.join(parts)}."
        await speak_hook(text, self._config.voice, self._config.tts_speed)
        return

    for change in changes:
        try:
            text = await self.analyze_alert(change)
            await speak_hook(text, self._config.voice, self._config.tts_speed)
        except Exception as e:
            _log.warning("[Grafana] 발화 실패: %s", e)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py -v
```

Expected: `13 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/grafana_poller.py tests/test_grafana_poller.py
git commit -m "feat: GrafanaPoller.run() — 폴링 루프 + burst 묶음 처리"
```

---

## Task 5: supervisor.py에 GrafanaPoller 통합

**Files:**
- Modify: `tts_server/supervisor.py`
- Modify: `tts_server/test_supervisor.py`

- [ ] **Step 1: 테스트 추가**

`tts_server/test_supervisor.py`를 읽어 기존 패턴 파악 후, 파일 끝에 추가:

```python
# tts_server/test_supervisor.py 끝에 추가
import asyncio
from unittest.mock import patch, MagicMock, AsyncMock
from tts_server.supervisor import main


async def test_grafana_poller_receives_shutdown():
    """supervisor shutdown 시 GrafanaPoller.run()도 종료된다."""
    from hook_voice.config import Config, GrafanaConfig
    from hook_voice.grafana_poller import GrafanaPoller

    config = Config(grafana=GrafanaConfig(enabled=False))
    poller = GrafanaPoller(config)

    shutdown = asyncio.Event()
    shutdown.set()  # 즉시 종료

    await poller.run(shutdown)  # enabled=False → 즉시 반환
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tts_server/test_supervisor.py::test_grafana_poller_receives_shutdown -v
```

Expected: `PASSED` (이 테스트는 통과해야 함 — import 확인용)

- [ ] **Step 3: supervisor.py에 poller 통합**

`tts_server/supervisor.py`의 import 블록 끝에 추가:
```python
from hook_voice.config import load_config
from hook_voice.grafana_poller import GrafanaPoller
```

`main()` 함수에서 `asyncio.gather()` 호출을 수정:

기존:
```python
        await asyncio.gather(
            player_loop(shutdown=shutdown),
            cleanup_loop(shutdown=shutdown),
            monitor_children(procs, shutdown=shutdown),
        )
```

변경 후:
```python
        config = load_config()
        poller = GrafanaPoller(config)
        log.info("[Supervisor] GrafanaPoller 준비 (enabled=%s)", config.grafana.enabled)

        await asyncio.gather(
            player_loop(shutdown=shutdown),
            cleanup_loop(shutdown=shutdown),
            monitor_children(procs, shutdown=shutdown),
            poller.run(shutdown),
        )
```

- [ ] **Step 4: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 전체 통과

- [ ] **Step 5: 커밋**

```bash
git add tts_server/supervisor.py tts_server/test_supervisor.py
git commit -m "feat: supervisor asyncio.gather에 GrafanaPoller 통합"
```

---

## Task 6: grafana CLI 서브커맨드 구현

사용자가 `.voice-persona.json`의 `grafana.alerts` 목록을 CLI로 관리할 수 있도록 한다.

**Files:**
- Modify: `hook_voice/hook_handlers.py`
- Modify: `hook_voice/__main__.py`
- Modify: `tests/test_grafana_poller.py`

- [ ] **Step 1: 테스트 추가**

`tests/test_grafana_poller.py` 끝에 추가:

```python
from hook_voice.hook_handlers import handle_grafana


async def test_grafana_list_empty(tmp_path, capsys):
    cfg = tmp_path / "persona.json"
    cfg.write_text('{}')
    await handle_grafana(["list"], cfg)
    out = capsys.readouterr().out
    assert "등록된 알럿이 없습니다" in out


async def test_grafana_add_and_list(tmp_path, capsys):
    cfg = tmp_path / "persona.json"
    cfg.write_text('{}')
    await handle_grafana(["add", "KafkaLag"], cfg)
    await handle_grafana(["list"], cfg)
    out = capsys.readouterr().out
    assert "KafkaLag" in out


async def test_grafana_remove(tmp_path, capsys):
    cfg = tmp_path / "persona.json"
    cfg.write_text('{"grafana": {"alerts": ["KafkaLag", "SparkFailed"]}}')
    await handle_grafana(["remove", "KafkaLag"], cfg)
    await handle_grafana(["list"], cfg)
    out = capsys.readouterr().out
    assert "KafkaLag" not in out
    assert "SparkFailed" in out


async def test_grafana_add_duplicate(tmp_path, capsys):
    cfg = tmp_path / "persona.json"
    cfg.write_text('{"grafana": {"alerts": ["KafkaLag"]}}')
    await handle_grafana(["add", "KafkaLag"], cfg)
    import json
    data = json.loads(cfg.read_text())
    assert data["grafana"]["alerts"].count("KafkaLag") == 1
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py::test_grafana_list_empty \
  tests/test_grafana_poller.py::test_grafana_add_and_list \
  tests/test_grafana_poller.py::test_grafana_remove \
  tests/test_grafana_poller.py::test_grafana_add_duplicate -v
```

Expected: `FAILED — cannot import name 'handle_grafana'`

- [ ] **Step 3: handle_grafana 구현 (hook_handlers.py 끝에 추가)**

```python
async def handle_grafana(args: list[str], config_path: "Path | None" = None) -> None:
    """grafana 서브커맨드 — 알럿 감시 목록 관리."""
    import json
    from .config import _DEFAULT_CONFIG_PATH

    target = config_path or _DEFAULT_CONFIG_PATH

    def _load_raw() -> dict:
        if not target.exists():
            return {}
        try:
            return json.loads(target.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _save_raw(data: dict) -> None:
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def _get_alerts(data: dict) -> list:
        return data.get("grafana", {}).get("alerts", [])

    def _set_alerts(data: dict, alerts: list) -> None:
        if "grafana" not in data:
            data["grafana"] = {}
        data["grafana"]["alerts"] = alerts

    if not args:
        print("Usage: python -m hook_voice grafana <list|add|remove>", flush=True)
        return

    sub = args[0]

    if sub == "list":
        data = _load_raw()
        alerts = _get_alerts(data)
        if not alerts:
            print("등록된 알럿이 없습니다.", flush=True)
        else:
            print(f"감시 중인 알럿 ({len(alerts)}개):", flush=True)
            for a in alerts:
                print(f"  - {a}", flush=True)

    elif sub == "add":
        if len(args) < 2:
            print("Usage: python -m hook_voice grafana add <알럿명>", flush=True)
            return
        name = args[1]
        data = _load_raw()
        alerts = _get_alerts(data)
        if name in alerts:
            print(f"이미 등록된 알럿입니다: {name}", flush=True)
            return
        alerts.append(name)
        _set_alerts(data, alerts)
        _save_raw(data)
        print(f"알럿 추가됨: {name}", flush=True)

    elif sub == "remove":
        if len(args) < 2:
            print("Usage: python -m hook_voice grafana remove <알럿명>", flush=True)
            return
        name = args[1]
        data = _load_raw()
        alerts = _get_alerts(data)
        if name not in alerts:
            print(f"등록되지 않은 알럿입니다: {name}", flush=True)
            return
        alerts.remove(name)
        _set_alerts(data, alerts)
        _save_raw(data)
        print(f"알럿 제거됨: {name}", flush=True)

    else:
        print(f"알 수 없는 서브커맨드: {sub}", flush=True)
```

- [ ] **Step 4: __main__.py에 grafana 서브커맨드 라우팅 추가**

`hook_voice/__main__.py`의 import 블록에 추가:
```python
from .hook_handlers import (
    ...
    handle_grafana,   # 추가
)
```

`main()` 함수의 `elif subcommand == "control":` 블록 다음에 추가:
```python
    elif subcommand == "grafana":
        await handle_grafana(sys.argv[2:], _DEFAULT_CONFIG_PATH)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_grafana_poller.py -v
```

Expected: `17 passed`

- [ ] **Step 6: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 전체 통과

- [ ] **Step 7: 커밋**

```bash
git add hook_voice/hook_handlers.py hook_voice/__main__.py tests/test_grafana_poller.py
git commit -m "feat: grafana CLI 서브커맨드 — add/remove/list 알럿 감시 목록 관리"
```

---

## Task 7: 수동 검증 및 설정 가이드

- [ ] **Step 1: .voice-persona.json 설정**

```bash
python -m hook_voice grafana add "KafkaLag"
python -m hook_voice grafana list
```

직접 `.voice-persona.json`에 Grafana 연결 정보 추가:
```json
{
  "grafana": {
    "enabled": true,
    "url": "http://<HMG-grafana-internal-host>:3000",
    "token": "glsa_<service-account-token>",
    "interval": 30,
    "alerts": ["KafkaLag"]
  }
}
```

- [ ] **Step 2: 폴링 동작 확인 (TTS 서버 실행 중 상태에서)**

```bash
./server.sh restart
./server.sh logs 30
```

로그에서 확인:
```
[Grafana] 폴링 시작 (interval=30s, alerts=['KafkaLag'])
[Grafana] 첫 폴링 완료 — snapshot 수집 (발화 없음)
```

- [ ] **Step 3: 최종 커밋**

```bash
git add .voice-persona.json   # 토큰 없이 설정 구조만 커밋 (token 제외)
git commit -m "docs: .voice-persona.json Grafana 설정 예시 구조 추가"
```

---

## 검증 기준

| 항목 | 기준 |
|------|------|
| 단위 테스트 | `pytest tests/ -v` 전체 통과 |
| 통합 테스트 | `pytest tts_server/ -v` 전체 통과 |
| Grafana 비활성 시 | 폴러 종료 없이 `shutdown.wait()` 대기 |
| 첫 폴링 | snapshot만 수집, 발화 없음 |
| 3개 초과 burst | 묶음 1회 발화 |
| LLM 실패 | 폴백 텍스트 발화 |
| 인증 실패 | 경고 로그 + poller 비활성화 |
