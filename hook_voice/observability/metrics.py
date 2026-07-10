# hook_voice/observability/metrics.py — Prometheus 메트릭 수집기
"""prometheus_client가 없어도 동작하는 경량 카운터/히스토그램 내장."""
from __future__ import annotations

import time
from collections import defaultdict, deque
from typing import Any

_HISTOGRAM_MAX_SAMPLES = 10_000  # 장기 운영 시 메모리 무한 증가 방지

try:
    import prometheus_client as _prom
    _HAS_PROM = True
except ImportError:
    _prom = None
    _HAS_PROM = False


# ── 경량 폴백 ──────────────────────────────────────────────────────────────────

class _SimpleCounter:
    def __init__(self) -> None:
        self._counts: dict[tuple, float] = defaultdict(float)

    def inc(self, labels: dict[str, str] | None = None, amount: float = 1.0) -> None:
        key = tuple(sorted((labels or {}).items()))
        self._counts[key] += amount

    def get(self, labels: dict[str, str] | None = None) -> float:
        key = tuple(sorted((labels or {}).items()))
        return self._counts.get(key, 0.0)

    def collect(self) -> dict:
        return {str(k): v for k, v in self._counts.items()}


class _SimpleHistogram:
    def __init__(self, buckets: list[float] | None = None) -> None:
        self._samples: deque[float] = deque(maxlen=_HISTOGRAM_MAX_SAMPLES)
        self._total_count: int = 0  # maxlen으로 잘린 것 포함한 전체 관측 횟수
        self._total_sum: float = 0.0
        self._buckets = buckets or [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]

    def observe(self, value: float) -> None:
        self._samples.append(value)
        self._total_count += 1
        self._total_sum += value

    def summary(self) -> dict:
        if self._total_count == 0:
            return {"count": 0, "sum": 0.0, "avg": 0.0}
        return {
            "count": self._total_count,
            "sum": self._total_sum,
            "avg": self._total_sum / self._total_count,
        }


# ── 메트릭 레지스트리 ──────────────────────────────────────────────────────────

class MetricsRegistry:
    """단일 인스턴스로 사용하는 메트릭 레지스트리."""

    def __init__(self) -> None:
        self.event_total = _SimpleCounter()
        self.event_discarded_total = _SimpleCounter()
        self.dlq_total = _SimpleCounter()
        self.tts_latency_ms = _SimpleHistogram()
        self.queue_depth_gauge: int = 0
        self._started_at = time.time()

    def record_event(self, source: str, event_type: str) -> None:
        self.event_total.inc({"source": source, "event_type": event_type})

    def record_discarded(self, reason: str) -> None:
        self.event_discarded_total.inc({"reason": reason})

    def record_dlq(self, failure_stage: str) -> None:
        self.dlq_total.inc({"failure_stage": failure_stage})

    def record_tts_latency(self, ms: float) -> None:
        self.tts_latency_ms.observe(ms)

    def set_queue_depth(self, depth: int) -> None:
        self.queue_depth_gauge = depth

    def snapshot(self) -> dict:
        return {
            "event_total": self.event_total.collect(),
            "event_discarded_total": self.event_discarded_total.collect(),
            "dlq_total": self.dlq_total.collect(),
            "tts_latency_ms": self.tts_latency_ms.summary(),
            "queue_depth": self.queue_depth_gauge,
            "uptime_seconds": time.time() - self._started_at,
        }

    def to_prometheus_text(self) -> str:
        """Prometheus text format (exposition format) 출력."""
        lines: list[str] = []
        snap = self.snapshot()

        lines.append("# HELP hook_voice_events_total Total processed events")
        lines.append("# TYPE hook_voice_events_total counter")
        for labels_str, count in snap["event_total"].items():
            lines.append(f"hook_voice_events_total{{{labels_str}}} {count}")

        lines.append("# HELP hook_voice_events_discarded_total Discarded events")
        lines.append("# TYPE hook_voice_events_discarded_total counter")
        for labels_str, count in snap["event_discarded_total"].items():
            lines.append(f"hook_voice_events_discarded_total{{{labels_str}}} {count}")

        lines.append("# HELP hook_voice_queue_depth Current event queue depth")
        lines.append("# TYPE hook_voice_queue_depth gauge")
        lines.append(f"hook_voice_queue_depth {snap['queue_depth']}")

        lat = snap["tts_latency_ms"]
        lines.append("# HELP hook_voice_tts_latency_ms TTS generation latency")
        lines.append("# TYPE hook_voice_tts_latency_ms summary")
        if lat["count"] > 0:
            lines.append(f'hook_voice_tts_latency_ms_count {lat["count"]}')
            lines.append(f'hook_voice_tts_latency_ms_sum {lat["sum"]:.1f}')

        return "\n".join(lines) + "\n"


# 모듈 싱글톤
_registry: MetricsRegistry | None = None


def get_registry() -> MetricsRegistry:
    global _registry
    if _registry is None:
        _registry = MetricsRegistry()
    return _registry
