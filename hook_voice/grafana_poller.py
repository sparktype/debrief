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
        """LLM으로 알럿 분석 — Task 3에서 구현됨, 지금은 폴백만 반환."""
        return f"{change.name} 알럿이 발생했습니다."

    async def run(self, shutdown: asyncio.Event) -> None:
        """supervisor에서 호출하는 폴링 루프 — Task 4에서 구현됨."""
        await shutdown.wait()
