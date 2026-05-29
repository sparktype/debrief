# hook_voice/observability/otel.py — OpenTelemetry 5 span 계측
"""OTel SDK가 없는 환경에서도 동작하도록 no-op 폴백을 내장한다."""
from __future__ import annotations

import contextlib
import logging
import time
from contextlib import asynccontextmanager, contextmanager
from typing import Any, Generator

_log = logging.getLogger(__name__)

# ── OTel SDK 선택적 임포트 ────────────────────────────────────────────────────

try:
    from opentelemetry import trace as _otel_trace
    from opentelemetry.trace import Status, StatusCode, SpanKind
    _HAS_OTEL = True
except ImportError:
    _HAS_OTEL = False

_TRACER_NAME = "hook_voice"


def _get_tracer():
    if _HAS_OTEL:
        return _otel_trace.get_tracer(_TRACER_NAME)
    return None


# ── Span 이름 상수 ─────────────────────────────────────────────────────────────

SPAN_INGEST_RECEIVE     = "ingest.receive"
SPAN_ADAPTER_TRANSFORM  = "adapter.transform"
SPAN_ROUTER_DISPATCH    = "router.dispatch"
SPAN_QUEUE_ENQUEUE      = "queue.enqueue"
SPAN_QUEUE_DEQUEUE      = "queue.dequeue"
SPAN_SINK_DELIVER       = "sink.deliver"


# ── 경량 Span 컨텍스트 (OTel 없을 때 사용) ──────────────────────────────────

class _NoOpSpan:
    def __init__(self, name: str) -> None:
        self.name = name
        self._start = time.time()

    def set_attribute(self, key: str, value: Any) -> None:
        pass

    def record_exception(self, exc: Exception) -> None:
        _log.debug("[Span:%s] exception: %s", self.name, exc)

    def set_status(self, *args, **kwargs) -> None:
        pass

    def end(self) -> None:
        elapsed = (time.time() - self._start) * 1000
        _log.debug("[Span:%s] %.1fms", self.name, elapsed)


@contextmanager
def start_span(name: str, attributes: dict | None = None) -> Generator[Any, None, None]:
    """동기 span 컨텍스트 매니저. OTel SDK 없으면 no-op span 반환."""
    tracer = _get_tracer()
    if tracer is not None:
        with tracer.start_as_current_span(name) as span:
            if attributes:
                for k, v in attributes.items():
                    span.set_attribute(k, v)
            yield span
    else:
        span = _NoOpSpan(name)
        if attributes:
            for k, v in (attributes or {}).items():
                span.set_attribute(k, v)
        try:
            yield span
        finally:
            span.end()


# ── 5 Span 헬퍼 ────────────────────────────────────────────────────────────────

def span_ingest_receive(source: str, event_type: str):
    return start_span(SPAN_INGEST_RECEIVE, {"source": source, "event_type": event_type})


def span_adapter_transform(source_id: str, raw_len: int):
    return start_span(SPAN_ADAPTER_TRANSFORM, {"source_id": source_id, "raw_len": raw_len})


def span_router_dispatch(source: str, event_type: str):
    return start_span(SPAN_ROUTER_DISPATCH, {"source": source, "event_type": event_type})


def span_queue_enqueue(priority_score: int, queue_depth: int):
    return start_span(SPAN_QUEUE_ENQUEUE, {
        "priority_score": priority_score,
        "queue_depth": queue_depth,
    })


def span_sink_deliver(tts_engine: str, text_len: int):
    return start_span(SPAN_SINK_DELIVER, {"tts_engine": tts_engine, "text_len": text_len})
