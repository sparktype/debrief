# tests/event/test_policy.py — PolicyDecisionEngine 단위 테스트
import asyncio
import time
import pytest

from hook_voice.event.canonical import CanonicalEvent
from hook_voice.event.policy import PolicyRules, InMemoryStateStore, PolicyDecisionEngine


async def test_normal_event_passes():
    rules = PolicyRules()
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev = CanonicalEvent(priority_score=50, raw_text="정상 이벤트")
    ok, reason = await engine.should_process(ev)
    assert ok
    assert reason == ""


async def test_low_priority_rejected():
    rules = PolicyRules(min_priority=20)
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev = CanonicalEvent(priority_score=10)
    ok, reason = await engine.should_process(ev)
    assert not ok
    assert "priority_score" in reason


async def test_duplicate_rejected():
    rules = PolicyRules(dedupe_ttl=60.0)
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev1 = CanonicalEvent(dedupe_key="key-abc", raw_text="첫 번째")
    ev2 = CanonicalEvent(dedupe_key="key-abc", raw_text="두 번째")
    ok1, _ = await engine.should_process(ev1)
    ok2, reason2 = await engine.should_process(ev2)
    assert ok1
    assert not ok2
    assert "중복" in reason2


async def test_duplicate_expires():
    rules = PolicyRules(dedupe_ttl=0.05)
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev = CanonicalEvent(dedupe_key="key-xyz")
    await engine.should_process(ev)
    await asyncio.sleep(0.1)
    ok, _ = await engine.should_process(CanonicalEvent(dedupe_key="key-xyz"))
    assert ok


async def test_empty_dedupe_key_no_dedup():
    rules = PolicyRules()
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev1 = CanonicalEvent(dedupe_key="")
    ev2 = CanonicalEvent(dedupe_key="")
    ok1, _ = await engine.should_process(ev1)
    ok2, _ = await engine.should_process(ev2)
    assert ok1 and ok2


async def test_expired_ttl_rejected():
    rules = PolicyRules()
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev = CanonicalEvent(ttl=0.001)
    await asyncio.sleep(0.01)
    ok, reason = await engine.should_process(ev)
    assert not ok
    assert "TTL" in reason


def test_truncate_text():
    rules = PolicyRules(max_text_len=10)
    store = InMemoryStateStore()
    engine = PolicyDecisionEngine(rules, store)
    ev = CanonicalEvent(raw_text="A" * 100)
    ev = engine.truncate_text(ev)
    assert len(ev.raw_text) == 10


async def test_purge_expired():
    store = InMemoryStateStore()
    await store.check_and_mark_duplicate("key-old", ttl=0.01)
    await asyncio.sleep(0.05)
    removed = await store.purge_expired(0.01)
    assert removed == 1


# SmartTTSRouter — SpeechPolicy 테스트 ───────────────────────────────────────

def test_error_gets_high_priority():
    """에러 감지 시 HIGH 우선순위 full 발화를 반환한다."""
    from hook_voice.event.policy import SpeechPolicy
    dec = SpeechPolicy.decide("테스트 실패했습니다. 오류를 확인해 주세요.", is_error=True)
    assert dec.priority == "HIGH"
    assert dec.mode == "full"


def test_short_ack_gets_low_priority():
    """짧은 확인 응답은 LOW 우선순위 earcon_only를 반환한다."""
    from hook_voice.event.policy import SpeechPolicy
    dec = SpeechPolicy.decide("완료됐습니다.", is_ack=True)
    assert dec.priority == "LOW"
    assert dec.mode == "earcon_only"


def test_normal_response():
    """일반 응답은 NORMAL 우선순위 full을 반환한다."""
    from hook_voice.event.policy import SpeechPolicy
    dec = SpeechPolicy.decide("파일을 분석했습니다. 총 15개의 함수가 있습니다.")
    assert dec.priority == "NORMAL"
    assert dec.mode in ("full", "summary_only")


def test_code_heavy_response():
    """코드 비중 높은 응답은 summary_only를 반환한다."""
    from hook_voice.event.policy import SpeechPolicy
    code_text = "코드\n" + "```python\n" + "x = 1\n" * 20 + "```"
    dec = SpeechPolicy.decide(code_text)
    assert dec.mode in ("summary_only", "earcon_only")
