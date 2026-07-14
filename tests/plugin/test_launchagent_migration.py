import subprocess

from hook_voice.runtime_manager import remove_legacy_launchagent_after_health
from hook_voice.runtime_paths import RuntimePaths


def test_legacy_agent_removed_only_after_health(tmp_path):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    legacy = tmp_path / "Library/LaunchAgents/com.voice-persona.tts-server.plist"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("legacy")
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0)

    assert remove_legacy_launchagent_after_health(paths, home=tmp_path, healthy=lambda: False, run=run) is False
    assert legacy.exists()
    assert remove_legacy_launchagent_after_health(paths, home=tmp_path, healthy=lambda: True, run=run) is True
    assert not legacy.exists()
    assert calls and "com.voice-persona.tts-server" in calls[0][-1]
