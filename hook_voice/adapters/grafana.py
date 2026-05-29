# hook_voice/adapters/grafana.py — Grafana alert → CanonicalEvent 변환 어댑터
from __future__ import annotations

import logging

from ..config import Config
from ..event.canonical import CanonicalEvent, InterruptPolicy, Severity
from ..grafana_poller import AlertChange, GrafanaPoller

_log = logging.getLogger(__name__)

_SEVERITY_MAP: dict[str, tuple[Severity, int, InterruptPolicy]] = {
    "critical": (Severity.CRITICAL, 90, InterruptPolicy.ALWAYS),
    "high":     (Severity.HIGH,     70, InterruptPolicy.ALWAYS),
    "warning":  (Severity.MEDIUM,   55, InterruptPolicy.QUEUE),
    "info":     (Severity.INFO,     35, InterruptPolicy.QUEUE),
}


class GrafanaSourceAdapter:
    """GrafanaPoller.poll_once()를 재사용해 CanonicalEvent를 생성하는 어댑터."""

    def __init__(self, config: Config) -> None:
        self._config = config
        self._poller = GrafanaPoller(config)

    def source_id(self) -> str:
        return "grafana"

    async def to_canonical_event(self, raw: str, **kwargs) -> CanonicalEvent | None:
        # raw 파싱 없이 AlertChange 직접 수신 경로도 지원
        change: AlertChange | None = kwargs.get("change")
        if change is None:
            return None
        return self._change_to_event(change)

    def change_to_event(self, change: AlertChange) -> CanonicalEvent:
        return self._change_to_event(change)

    def _change_to_event(self, change: AlertChange) -> CanonicalEvent:
        sev_label = change.labels.get("severity", "info").lower()
        severity, priority, policy = _SEVERITY_MAP.get(
            sev_label, (Severity.INFO, 35, InterruptPolicy.QUEUE)
        )

        if change.status == "resolved":
            severity = Severity.LOW
            priority = 50
            policy = InterruptPolicy.QUEUE

        event_type = f"alert_{change.status}"  # "alert_firing" | "alert_resolved"
        summary = (
            change.annotations.get("summary")
            or change.annotations.get("description")
            or change.name
        )
        fingerprint = f"grafana:{change.name}:{change.status}"

        return CanonicalEvent(
            source=self.source_id(),
            source_event_type=event_type,
            severity=severity,
            priority_score=priority,
            interrupt_policy=policy,
            raw_text=summary,
            fingerprint=fingerprint,
            dedupe_key=f"{fingerprint}:{change.started_at.isoformat()}",
            ttl=300.0,  # Grafana 이벤트는 5분 TTL
            metadata={
                "alert_name": change.name,
                "labels": change.labels,
                "value": change.value,
                "started_at": change.started_at.isoformat(),
                "duration_secs": change.duration.total_seconds() if change.duration else None,
            },
        )

    async def health_check(self) -> bool:
        g = self._config.grafana
        if not g.enabled or not g.url or not g.token:
            return False
        result = await self._poller.poll_once()
        return result.ok
