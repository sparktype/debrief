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
