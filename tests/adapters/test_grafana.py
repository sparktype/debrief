# tests/adapters/test_grafana.py — GrafanaSourceAdapter 단위 테스트
import json
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock, patch
import pytest

from hook_voice.adapters.grafana import GrafanaSourceAdapter
from hook_voice.config import Config, GrafanaConfig
from hook_voice.grafana_poller import AlertChange, PollResult
from hook_voice.event.canonical import Severity, InterruptPolicy


def _config(enabled=True, url="http://grafana.test", token="tok"):
    cfg = Config()
    cfg.grafana = GrafanaConfig(enabled=enabled, url=url, token=token, alerts=["TestAlert"])
    return cfg


@pytest.fixture
def adapter():
    return GrafanaSourceAdapter(_config())


def _make_change(name="TestAlert", status="firing", sev="critical"):
    return AlertChange(
        name=name,
        status=status,
        labels={"alertname": name, "severity": sev},
        annotations={"summary": "테스트 알럿 요약"},
        value="100",
        started_at=datetime.now(timezone.utc),
        duration=timedelta(minutes=5) if status == "resolved" else None,
    )


def test_source_id(adapter):
    assert adapter.source_id() == "grafana"


def test_firing_critical_priority(adapter):
    change = _make_change(status="firing", sev="critical")
    ev = adapter.change_to_event(change)
    assert ev.severity == Severity.CRITICAL
    assert ev.priority_score == 90
    assert ev.interrupt_policy == InterruptPolicy.ALWAYS


def test_firing_high_priority(adapter):
    change = _make_change(status="firing", sev="high")
    ev = adapter.change_to_event(change)
    assert ev.severity == Severity.HIGH
    assert ev.priority_score == 70


def test_resolved_priority(adapter):
    change = _make_change(status="resolved", sev="critical")
    ev = adapter.change_to_event(change)
    assert ev.priority_score == 50
    assert ev.interrupt_policy == InterruptPolicy.QUEUE


def test_event_metadata(adapter):
    change = _make_change()
    ev = adapter.change_to_event(change)
    assert ev.metadata["alert_name"] == "TestAlert"
    assert ev.metadata["value"] == "100"
    assert "started_at" in ev.metadata


def test_event_ttl(adapter):
    change = _make_change()
    ev = adapter.change_to_event(change)
    assert ev.ttl == 300.0


async def test_health_check_ok(adapter):
    with patch.object(adapter._poller, "poll_once", return_value=PollResult(ok=True, snapshot={})):
        assert await adapter.health_check() is True


async def test_health_check_fail(adapter):
    with patch.object(
        adapter._poller, "poll_once",
        return_value=PollResult(ok=False, error_kind="network", error_detail="timeout"),
    ):
        assert await adapter.health_check() is False


async def test_health_check_disabled():
    cfg = _config(enabled=False)
    a = GrafanaSourceAdapter(cfg)
    assert await a.health_check() is False
