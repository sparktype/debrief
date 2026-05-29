# tests/event/test_queue.py — InMemoryEventQueue 단위 테스트
import asyncio
import pytest

from hook_voice.event.canonical import CanonicalEvent, InterruptPolicy
from hook_voice.event.queue import InMemoryEventQueue, HWM, LWM


async def test_publish_and_consume():
    q = InMemoryEventQueue()
    ev = CanonicalEvent(raw_text="hello", priority_score=50)
    ok = await q.publish(ev)
    assert ok
    events = await q.consume()
    assert len(events) == 1
    assert events[0].event_id == ev.event_id


async def test_priority_order():
    q = InMemoryEventQueue()
    low = CanonicalEvent(priority_score=10, raw_text="low")
    high = CanonicalEvent(priority_score=90, raw_text="high")
    await q.publish(low)
    await q.publish(high)
    events = await q.consume(batch_size=2)
    assert events[0].raw_text == "high"
    assert events[1].raw_text == "low"


async def test_hwm_discards_discard_policy():
    q = InMemoryEventQueue(hwm=2, lwm=1)
    for _ in range(2):
        await q.publish(CanonicalEvent(priority_score=30))
    # HWM 도달 — DISCARD 정책 이벤트 거부
    ev = CanonicalEvent(priority_score=5, interrupt_policy=InterruptPolicy.DISCARD)
    ok = await q.publish(ev)
    assert not ok


async def test_hwm_allows_queue_policy():
    q = InMemoryEventQueue(hwm=2, lwm=1)
    for _ in range(2):
        await q.publish(CanonicalEvent(priority_score=30))
    # QUEUE 정책은 HWM 초과 시에도 허용
    ev = CanonicalEvent(priority_score=50, interrupt_policy=InterruptPolicy.QUEUE)
    ok = await q.publish(ev)
    assert ok


async def test_expired_event_goes_to_dlq():
    import time
    q = InMemoryEventQueue()
    ev = CanonicalEvent(ttl=0.001)
    await asyncio.sleep(0.01)
    ok = await q.publish(ev)
    assert not ok
    assert len(q.dlq) == 1
    assert q.dlq[0]["failure_stage"] == "queue_enqueue"


async def test_metrics():
    q = InMemoryEventQueue()
    await q.publish(CanonicalEvent(priority_score=10))
    await q.consume()
    m = await q.get_metrics()
    assert m["published"] == 1
    assert m["consumed"] == 1
    assert m["queue_depth"] == 0


async def test_consume_empty_returns_empty():
    q = InMemoryEventQueue()
    events = await q.consume()
    assert events == []
