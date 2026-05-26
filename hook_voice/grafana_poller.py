# Grafana Alertmanager API 폴링 — 상태 변화 감지 및 TTS 발화
import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from typing import Literal

import httpx

from .config import Config
from .llm_client import chat_completion

_log = logging.getLogger(__name__)

_ZERO_TIME = "0001-01-01T00:00:00Z"


@dataclass
class AlertChange:
    name: str
    status: Literal["firing", "resolved"]
    labels: dict[str, str]
    annotations: dict[str, str]
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
            # HMG 사내 SSL 인터셉트 프록시 우회
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
        if change.status == "resolved":
            mins = int(change.duration.total_seconds() // 60) if change.duration else 0
            return f"{change.name} 알럿이 해소되었습니다. {mins}분 만에 복구됐습니다."

        summary = (
            change.annotations.get("summary")
            or change.annotations.get("description")
            or "(설명 없음)"
        )
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

    async def run(self, shutdown: asyncio.Event) -> None:
        """supervisor에서 호출하는 폴링 루프 — Task 4에서 구현됨."""
        await shutdown.wait()
