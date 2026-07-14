import json
import os
import subprocess
from pathlib import Path


RUNNER = Path("plugins/chorus/scripts/chorus-hook").resolve()


def test_hook_runner_fails_open_and_records_error(tmp_path):
    env = os.environ.copy()
    env.update({
        "HOME": str(tmp_path),
        "CHORUS_HOOK_EVENT": "Stop",
        "CHORUS_HOOK_SOURCE": "codex",
        "CHORUS_HOOK_URL": "http://127.0.0.1:9/hooks/events",
    })
    result = subprocess.run([str(RUNNER)], input='{"session_id":"s1"}', text=True, env=env, capture_output=True, timeout=2)
    assert result.returncode == 0
    error = json.loads((tmp_path / ".local/share/chorus/last_hook_delivery_error.json").read_text())
    assert error["source"] == "codex"
    assert error["event_name"] == "Stop"


def test_hook_runner_accepts_invalid_json_without_blocking(tmp_path):
    env = os.environ.copy()
    env.update({"HOME": str(tmp_path), "CHORUS_HOOK_URL": "http://127.0.0.1:9/hooks/events"})
    result = subprocess.run([str(RUNNER)], input="not-json", text=True, env=env, timeout=2)
    assert result.returncode == 0
