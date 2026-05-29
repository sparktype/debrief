# tests/adapters/test_coding_agent.py — CodingAgentAdapter 단위 테스트
import json
import pytest

from hook_voice.adapters.coding_agent import CodingAgentAdapter
from hook_voice.event.canonical import Severity, InterruptPolicy


@pytest.fixture
def adapter():
    return CodingAgentAdapter()


def test_source_id(adapter):
    assert adapter.source_id() == "coding_agent"


async def test_stop_event(adapter):
    raw = json.dumps({"last_assistant_message": "작업 완료됐습니다."})
    ev = await adapter.to_canonical_event(raw, event_type="stop")
    assert ev is not None
    assert ev.source == "coding_agent"
    assert ev.source_event_type == "stop"
    assert ev.raw_text == "작업 완료됐습니다."
    assert ev.priority_score == 40
    assert ev.interrupt_policy == InterruptPolicy.QUEUE


async def test_subagent_stop_with_agent_type(adapter):
    raw = json.dumps({"last_assistant_message": "리뷰 완료"})
    ev = await adapter.to_canonical_event(raw, event_type="subagent_stop", agent_type="code-reviewer")
    assert ev is not None
    assert ev.metadata.get("agent_type") == "code-reviewer"
    assert ev.priority_score == 30


async def test_pre_tool_bash_discard_policy(adapter):
    raw = json.dumps({"last_assistant_message": "빌드 시작"})
    ev = await adapter.to_canonical_event(raw, event_type="pre_tool_bash")
    assert ev is not None
    assert ev.interrupt_policy == InterruptPolicy.DISCARD
    assert ev.priority_score == 10


async def test_invalid_json_uses_raw(adapter):
    raw = "이것은 JSON이 아닙니다"
    ev = await adapter.to_canonical_event(raw, event_type="stop")
    assert ev is not None
    assert ev.raw_text == raw


async def test_empty_raw(adapter):
    ev = await adapter.to_canonical_event("", event_type="stop")
    assert ev is not None
    assert ev.raw_text == ""


async def test_health_check(adapter):
    assert await adapter.health_check() is True


async def test_fingerprint_consistency(adapter):
    raw = json.dumps({"last_assistant_message": "같은 내용"})
    ev1 = await adapter.to_canonical_event(raw, event_type="stop")
    ev2 = await adapter.to_canonical_event(raw, event_type="stop")
    assert ev1.fingerprint == ev2.fingerprint
