import json
from pathlib import Path

import pytest

from hook_voice.event.hook_event import adapt_hook_payload


FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture(params=["claude", "codex"])
def provider_payloads(request):
    return request.param, json.loads((FIXTURES / f"{request.param}_hooks.json").read_text())


def test_all_shared_payloads_normalize(provider_payloads):
    provider, payloads = provider_payloads
    for name, payload in payloads.items():
        event = adapt_hook_payload(payload, source=provider, event_name=name, env={"HOME": "/tmp"})
        assert event.source == provider
        assert event.event_name == name
        assert event.session_id.endswith("-s1")


def test_payload_values_win_over_environment():
    event = adapt_hook_payload(
        {"session_id": "payload", "cwd": "/payload"},
        source="claude",
        event_name="SessionStart",
        env={"HOME": "/home/test", "CLAUDE_CODE_SESSION_ID": "fallback", "CLAUDE_PROJECT_DIR": "/fallback"},
    )
    assert event.session_id == "payload"
    assert event.cwd == Path("/payload")


def test_claude_legacy_payload_derives_transcript_path():
    event = adapt_hook_payload(
        {}, source="claude", event_name="Stop",
        env={"HOME": "/home/test", "CLAUDE_CODE_SESSION_ID": "s1", "CLAUDE_PROJECT_DIR": "/work/project"},
    )
    assert event.transcript_path == Path("/home/test/.claude/projects/-work-project/s1.jsonl")
