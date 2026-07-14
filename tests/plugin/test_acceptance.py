import json
import os
import subprocess
from pathlib import Path

from hook_voice.runtime_manager import apply_privacy_preset, install_release
from hook_voice.runtime_paths import RuntimePaths


def test_fresh_local_setup_offline_hook_and_update_persistence(tmp_path):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    runtime = Path("plugins/chorus/runtime")
    first = install_release(runtime, "1.0.0", paths)
    config = apply_privacy_preset("local", paths.config)
    assert config["configured"] is True
    assert config["externalLlm"] is False
    assert config["usageTracking"] is False

    env = os.environ.copy()
    env.update({
        "HOME": str(tmp_path),
        "CHORUS_HOOK_SOURCE": "codex",
        "CHORUS_HOOK_EVENT": "Stop",
        "CHORUS_HOOK_URL": "http://127.0.0.1:9/hooks/events",
    })
    hook = subprocess.run(
        [str(Path("plugins/chorus/scripts/chorus-hook").resolve())],
        input='{"conversationId":"s1"}', text=True, env=env, timeout=2,
    )
    assert hook.returncode == 0
    assert paths.data_dir.joinpath("last_hook_delivery_error.json").exists()

    second = install_release(runtime, "1.0.1", paths)
    assert paths.current.resolve() == second.release
    assert first.release.exists()
    assert json.loads(paths.config.read_text())["privacyPreset"] == "local"
