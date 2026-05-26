# Grafana Alertmanager API 폴링 — 상태 변화 감지 및 TTS 발화
import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from typing import Literal

import httpx

from .config import Config
from .llm_client import chat_completion
from .player import speak_hook

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

    # 동일 fingerprint의 value 변화는 감지하지 않음 — firing 지속 중 재발화 방지
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
            _log.warning("[Grafana] 폴링 실패: %s", type(e).__name__)
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
        """supervisor에서 호출하는 폴링 루프."""
        g = self._config.grafana
        if not g.enabled or not g.url or not g.token:
            _log.info("[Grafana] 폴러 비활성화 (enabled=False 또는 url/token 미설정)")
            await shutdown.wait()
            return

        _log.info("[Grafana] 폴링 시작 (interval=%ds, alerts=%s)", g.interval, g.alerts)
        prev_snapshot: dict = {}
        first_run = True

        while not shutdown.is_set():
            try:
                curr = await self.poll_once()
            except PermissionError as e:
                _log.error("[Grafana] %s — 폴러를 비활성화합니다.", e)
                await speak_hook(
                    "Grafana 인증에 실패했습니다. 토큰을 확인해 주세요.",
                    self._config.voice,
                    self._config.tts_speed,
                )
                break

            if first_run:
                prev_snapshot = curr
                first_run = False
                _log.info("[Grafana] 첫 폴링 완료 — snapshot 수집 (발화 없음)")
            else:
                changes = _detect_changes(prev_snapshot, curr, g.alerts)
                if changes:
                    await self._handle_changes(changes)
                prev_snapshot = curr

            try:
                await asyncio.wait_for(shutdown.wait(), timeout=float(g.interval))
            except asyncio.TimeoutError:
                pass

    async def _handle_changes(self, changes: list[AlertChange]) -> None:
        """알럿 변화를 TTS로 발화. 3개 초과 시 묶음 요약."""
        if len(changes) > 3:
            firing = sum(1 for c in changes if c.status == "firing")
            resolved = sum(1 for c in changes if c.status == "resolved")
            parts = []
            if firing:
                parts.append(f"발생 {firing}개")
            if resolved:
                parts.append(f"해소 {resolved}개")
            text = f"{len(changes)}개 알럿 상태가 변경됐습니다. {', '.join(parts)}."
            await speak_hook(text, self._config.voice, self._config.tts_speed)
            return

        for change in changes:
            try:
                text = await self.analyze_alert(change)
                await speak_hook(text, self._config.voice, self._config.tts_speed)
            except Exception as e:
                _log.warning("[Grafana] 발화 실패: %s", e)
