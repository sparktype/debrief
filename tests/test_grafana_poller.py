# Grafana 폴러 — AlertChange dataclass, poll_once, _detect_changes 단위 테스트
import asyncio
import pytest
from datetime import datetime, timezone, timedelta
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
    mock_response.status_code = 200

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


async def test_poll_once_raises_on_401():
    config = _make_config()
    poller = GrafanaPoller(config)
    mock_response = MagicMock()
    mock_response.status_code = 401
    mock_response.raise_for_status = MagicMock()

    with patch("hook_voice.grafana_poller.httpx.AsyncClient") as mock_client_cls:
        mock_client = AsyncMock()
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client_cls.return_value = mock_client

        with pytest.raises(PermissionError):
            await poller.poll_once()


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
    assert "firing" in statuses
    assert "resolved" in statuses


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


async def test_run_disabled_exits_immediately():
    """grafana.enabled=False 이면 즉시 종료."""
    config = Config(grafana=GrafanaConfig(enabled=False))
    poller = GrafanaPoller(config)
    shutdown = asyncio.Event()
    shutdown.set()
    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak:
        await poller.run(shutdown)
        mock_speak.assert_not_called()


async def test_run_first_cycle_no_speak():
    """첫 사이클은 snapshot만 수집하고 발화하지 않는다."""
    config = _make_config(alerts=["KafkaLag"])
    poller = GrafanaPoller(config)
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
    shutdown = asyncio.Event()
    call_count = 0

    async def fake_poll():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return {}
        shutdown.set()
        return {"fp001": SAMPLE_ALERT}

    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak, \
         patch.object(poller, "analyze_alert", new=AsyncMock(return_value="Kafka 알럿입니다.")):
        await poller.run(shutdown)
        mock_speak.assert_called_once()


async def test_run_burst_over_3_alerts():
    """3개 초과 알럿은 묶음 1회만 발화한다."""
    config = _make_config(alerts=["A1", "A2", "A3", "A4"])
    poller = GrafanaPoller(config)
    shutdown = asyncio.Event()
    call_count = 0

    alerts = [
        {**SAMPLE_ALERT, "fingerprint": f"fp{i}",
         "labels": {"alertname": f"A{i}", "severity": "critical"}}
        for i in range(1, 5)
    ]

    async def fake_poll():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return {}
        shutdown.set()
        return {a["fingerprint"]: a for a in alerts}

    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak:
        await poller.run(shutdown)
        assert mock_speak.call_count == 1
        text = mock_speak.call_args[0][0]
        assert "4개" in text


async def test_run_auth_failure_speaks_warning_and_exits():
    """401/403 인증 실패 시 경고 TTS 1회 발화 후 종료."""
    config = _make_config()
    poller = GrafanaPoller(config)
    shutdown = asyncio.Event()

    async def fake_poll():
        raise PermissionError("Grafana 인증 실패 (HTTP 401)")

    poller.poll_once = fake_poll

    with patch("hook_voice.grafana_poller.speak_hook", new=AsyncMock()) as mock_speak:
        await poller.run(shutdown)
        mock_speak.assert_called_once()
        text = mock_speak.call_args[0][0]
        assert "인증" in text
