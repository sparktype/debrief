import asyncio
import pytest

from hook_voice import hook_ingest
from hook_voice.runtime_paths import RuntimePaths, atomic_write_json


@pytest.mark.asyncio
async def test_hook_ingest_is_inert_before_setup(tmp_path, monkeypatch):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    called = False

    async def fake_dispatch(*args):
        nonlocal called
        called = True

    monkeypatch.setattr(hook_ingest, "dispatch_hook_event", fake_dispatch)
    result = await hook_ingest.ingest_hook_event("claude", "Stop", {}, paths=paths)
    await asyncio.sleep(0)
    assert result == {"accepted": True, "active": False}
    assert called is False


@pytest.mark.asyncio
async def test_hook_ingest_normalizes_and_dispatches_after_setup(tmp_path, monkeypatch):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    atomic_write_json(paths.config, {"configured": True, "autoSpeak": False})
    received = []

    async def fake_dispatch(event, config):
        received.append((event, config))

    monkeypatch.setattr(hook_ingest, "dispatch_hook_event", fake_dispatch)
    result = await hook_ingest.ingest_hook_event(
        "codex", "Stop", {"conversationId": "s1", "assistantMessage": "done"}, paths=paths
    )
    await asyncio.sleep(0)
    assert result == {"accepted": True, "active": True}
    assert received[0][0].session_id == "s1"
    import json
    assert json.loads((paths.data_dir / "last_hook_delivery_codex.json").read_text())["event_name"] == "Stop"
