# tests/observability/test_otel.py — OTel span 계측 단위 테스트
import pytest

from hook_voice.observability.otel import (
    start_span,
    span_ingest_receive,
    span_adapter_transform,
    span_router_dispatch,
    span_queue_enqueue,
    span_sink_deliver,
    _NoOpSpan,
    SPAN_INGEST_RECEIVE,
    SPAN_ADAPTER_TRANSFORM,
    SPAN_ROUTER_DISPATCH,
    SPAN_QUEUE_ENQUEUE,
    SPAN_SINK_DELIVER,
)


def test_start_span_yields_span():
    with start_span("test.span") as span:
        assert span is not None


def test_noop_span_set_attribute_no_raise():
    span = _NoOpSpan("test")
    span.set_attribute("key", "value")  # should not raise


def test_noop_span_record_exception_no_raise():
    span = _NoOpSpan("test")
    span.record_exception(ValueError("boom"))  # should not raise


def test_noop_span_set_status_no_raise():
    span = _NoOpSpan("test")
    span.set_status("ok")  # should not raise


def test_noop_span_end_no_raise():
    span = _NoOpSpan("test")
    span.end()  # should not raise


def test_start_span_with_attributes():
    with start_span("tagged.span", attributes={"source": "test", "count": 3}) as span:
        assert span is not None


def test_start_span_without_attributes():
    with start_span("bare.span") as span:
        assert span is not None


def test_start_span_exception_propagates():
    with pytest.raises(RuntimeError):
        with start_span("err.span"):
            raise RuntimeError("intentional")


def test_span_ingest_receive_returns_cm():
    cm = span_ingest_receive("grafana", "alert")
    with cm as span:
        assert span is not None


def test_span_adapter_transform_returns_cm():
    with span_adapter_transform("src-001", raw_len=256) as span:
        assert span is not None


def test_span_router_dispatch_returns_cm():
    with span_router_dispatch("coding_agent", "stop") as span:
        assert span is not None


def test_span_queue_enqueue_returns_cm():
    with span_queue_enqueue(priority_score=40, queue_depth=5) as span:
        assert span is not None


def test_span_sink_deliver_returns_cm():
    with span_sink_deliver(tts_engine="edge_tts", text_len=120) as span:
        assert span is not None


def test_span_constants_unique():
    names = {
        SPAN_INGEST_RECEIVE,
        SPAN_ADAPTER_TRANSFORM,
        SPAN_ROUTER_DISPATCH,
        SPAN_QUEUE_ENQUEUE,
        SPAN_SINK_DELIVER,
    }
    assert len(names) == 5
