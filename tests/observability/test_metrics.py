# tests/observability/test_metrics.py — Prometheus 메트릭 레지스트리 단위 테스트
import pytest

from hook_voice.observability.metrics import MetricsRegistry, _SimpleCounter, _SimpleHistogram


# ── _SimpleCounter ─────────────────────────────────────────────────────────────

def test_counter_initial_zero():
    c = _SimpleCounter()
    assert c.get() == 0.0


def test_counter_inc_no_labels():
    c = _SimpleCounter()
    c.inc()
    assert c.get() == 1.0


def test_counter_inc_multiple():
    c = _SimpleCounter()
    c.inc(); c.inc(); c.inc()
    assert c.get() == 3.0


def test_counter_inc_with_amount():
    c = _SimpleCounter()
    c.inc(amount=5.0)
    assert c.get() == 5.0


def test_counter_inc_with_labels():
    c = _SimpleCounter()
    c.inc({"source": "grafana", "event_type": "alert"})
    c.inc({"source": "grafana", "event_type": "alert"})
    assert c.get({"source": "grafana", "event_type": "alert"}) == 2.0


def test_counter_different_labels_independent():
    c = _SimpleCounter()
    c.inc({"source": "grafana"})
    c.inc({"source": "coding_agent"})
    assert c.get({"source": "grafana"}) == 1.0
    assert c.get({"source": "coding_agent"}) == 1.0


def test_counter_collect_returns_dict():
    c = _SimpleCounter()
    c.inc({"reason": "expired"})
    result = c.collect()
    assert isinstance(result, dict)
    assert len(result) == 1


# ── _SimpleHistogram ───────────────────────────────────────────────────────────

def test_histogram_empty_summary():
    h = _SimpleHistogram()
    s = h.summary()
    assert s["count"] == 0
    assert s["sum"] == 0.0
    assert s["avg"] == 0.0


def test_histogram_observe_single():
    h = _SimpleHistogram()
    h.observe(100.0)
    s = h.summary()
    assert s["count"] == 1
    assert s["sum"] == 100.0
    assert s["avg"] == 100.0


def test_histogram_observe_multiple():
    h = _SimpleHistogram()
    h.observe(100.0)
    h.observe(200.0)
    s = h.summary()
    assert s["count"] == 2
    assert s["avg"] == 150.0


# ── MetricsRegistry ────────────────────────────────────────────────────────────

def test_registry_record_event():
    reg = MetricsRegistry()
    reg.record_event("grafana", "alert")
    reg.record_event("grafana", "alert")
    assert reg.event_total.get({"source": "grafana", "event_type": "alert"}) == 2.0


def test_registry_record_discarded():
    reg = MetricsRegistry()
    reg.record_discarded("expired")
    assert reg.event_discarded_total.get({"reason": "expired"}) == 1.0


def test_registry_record_dlq():
    reg = MetricsRegistry()
    reg.record_dlq("tts_generate")
    assert reg.dlq_total.get({"failure_stage": "tts_generate"}) == 1.0


def test_registry_record_tts_latency():
    reg = MetricsRegistry()
    reg.record_tts_latency(250.0)
    reg.record_tts_latency(350.0)
    s = reg.tts_latency_ms.summary()
    assert s["count"] == 2
    assert s["avg"] == 300.0


def test_registry_set_queue_depth():
    reg = MetricsRegistry()
    reg.set_queue_depth(42)
    assert reg.queue_depth_gauge == 42


def test_registry_snapshot_keys():
    reg = MetricsRegistry()
    snap = reg.snapshot()
    assert "event_total" in snap
    assert "event_discarded_total" in snap
    assert "dlq_total" in snap
    assert "tts_latency_ms" in snap
    assert "queue_depth" in snap
    assert "uptime_seconds" in snap


def test_registry_uptime_positive():
    import time
    reg = MetricsRegistry()
    time.sleep(0.01)
    snap = reg.snapshot()
    assert snap["uptime_seconds"] > 0


def test_prometheus_text_contains_headers():
    reg = MetricsRegistry()
    reg.record_event("grafana", "alert")
    text = reg.to_prometheus_text()
    assert "# HELP hook_voice_events_total" in text
    assert "# TYPE hook_voice_events_total counter" in text


def test_prometheus_text_counter_line():
    reg = MetricsRegistry()
    reg.record_event("coding_agent", "stop")
    text = reg.to_prometheus_text()
    assert "hook_voice_events_total" in text
    assert "coding_agent" in text


def test_prometheus_text_queue_depth():
    reg = MetricsRegistry()
    reg.set_queue_depth(7)
    text = reg.to_prometheus_text()
    assert "hook_voice_queue_depth 7" in text


def test_prometheus_text_tts_latency_when_empty():
    reg = MetricsRegistry()
    text = reg.to_prometheus_text()
    # count=0이면 latency 라인 미출력
    assert "hook_voice_tts_latency_ms_count" not in text


def test_prometheus_text_tts_latency_when_observed():
    reg = MetricsRegistry()
    reg.record_tts_latency(500.0)
    text = reg.to_prometheus_text()
    assert "hook_voice_tts_latency_ms_count 1" in text
    assert "hook_voice_tts_latency_ms_sum 500.0" in text
