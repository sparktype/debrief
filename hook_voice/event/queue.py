# hook_voice/event/queue.py — 메모리 기반 우선순위 이벤트 큐
from __future__ import annotations

import asyncio
import logging
from typing import Protocol, runtime_checkable

from .canonical import CanonicalEvent, InterruptPolicy

_log = logging.getLogger(__name__)

HWM = 800   # High-Water Mark — 이 이상이면 DISCARD 정책 이벤트 거부
LWM = 200   # Low-Water Mark — 이 이하면 정상 수신 재개


@runtime_checkable
class EventQueueProtocol(Protocol):
    async def publish(self, event: CanonicalEvent, partition_key: str = "") -> bool: ...
    async def consume(self, consumer_group: str = "", batch_size: int = 1) -> list[CanonicalEvent]: ...
    async def acknowledge(self, event_id: str) -> None: ...
    async def publish_to_dlq(self, event: CanonicalEvent, failure_stage: str, detail: str) -> None: ...
    async def get_metrics(self) -> dict: ...


class InMemoryEventQueue:
    """asyncio.PriorityQueue 기반 인메모리 이벤트 큐.

    정렬 기준: (-priority_score, created_at) — 높은 우선순위가 먼저 소비된다.
    """

    def __init__(self, hwm: int = HWM, lwm: int = LWM) -> None:
        self._hwm = hwm
        self._lwm = lwm
        self._queue: asyncio.PriorityQueue[tuple[tuple, CanonicalEvent]] = asyncio.PriorityQueue()
        self._dlq: list[dict] = []
        self._throttled = False
        self._published = 0
        self._consumed = 0
        self._discarded = 0

    def _sort_key(self, ev: CanonicalEvent) -> tuple:
        return (-ev.priority_score, ev.created_at)

    async def publish(self, event: CanonicalEvent, partition_key: str = "") -> bool:
        depth = self._queue.qsize()

        if depth >= self._hwm:
            if not self._throttled:
                _log.warning("[Queue] HWM %d 초과 — DISCARD 정책 이벤트 거부 시작", self._hwm)
                self._throttled = True
            if event.interrupt_policy == InterruptPolicy.DISCARD:
                self._discarded += 1
                return False

        if event.is_expired():
            await self.publish_to_dlq(event, "queue_enqueue", "TTL 만료")
            return False

        await self._queue.put((self._sort_key(event), event))
        self._published += 1

        if self._throttled and self._queue.qsize() <= self._lwm:
            _log.info("[Queue] LWM %d 이하 복구 — 정상 수신 재개", self._lwm)
            self._throttled = False

        return True

    async def consume(self, consumer_group: str = "", batch_size: int = 1) -> list[CanonicalEvent]:
        events: list[CanonicalEvent] = []
        for _ in range(batch_size):
            if self._queue.empty():
                break
            try:
                _, event = self._queue.get_nowait()
                self._consumed += 1
                events.append(event)
            except asyncio.QueueEmpty:
                break
        return events

    async def consume_wait(self, timeout: float = 1.0) -> CanonicalEvent | None:
        """이벤트가 올 때까지 최대 timeout초 대기."""
        try:
            _, event = await asyncio.wait_for(self._queue.get(), timeout=timeout)
            self._consumed += 1
            return event
        except asyncio.TimeoutError:
            return None

    async def acknowledge(self, event_id: str) -> None:
        pass  # 인메모리 큐는 get 시점에 소비 완료

    async def publish_to_dlq(self, event: CanonicalEvent, failure_stage: str, detail: str) -> None:
        self._dlq.append({
            "event_id": event.event_id,
            "idempotency_key": event.idempotency_key,
            "failure_stage": failure_stage,
            "error_detail": detail,
            "replay_status": "pending",
        })
        _log.warning("[DLQ] event_id=%s stage=%s detail=%s", event.event_id, failure_stage, detail)

    async def get_metrics(self) -> dict:
        return {
            "queue_depth": self._queue.qsize(),
            "published": self._published,
            "consumed": self._consumed,
            "discarded": self._discarded,
            "dlq_size": len(self._dlq),
            "throttled": self._throttled,
        }

    def qsize(self) -> int:
        return self._queue.qsize()

    @property
    def dlq(self) -> list[dict]:
        return list(self._dlq)
