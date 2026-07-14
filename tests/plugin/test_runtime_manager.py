import json
from pathlib import Path

import pytest

from hook_voice.runtime_manager import ReleaseValidationError, apply_privacy_preset, ensure_runtime_environment, install_release, render_launchagent, uninstall_runtime
from hook_voice.runtime_paths import RuntimePaths


def paths(tmp_path):
    return RuntimePaths.from_environment({"HOME": str(tmp_path)})


def runtime_fixture(tmp_path, marker="one"):
    source = tmp_path / f"source-{marker}"
    (source / "hook_voice").mkdir(parents=True)
    (source / "tts_server").mkdir()
    (source / "hook_voice/__init__.py").write_text(f"MARKER = {marker!r}\n")
    (source / "tts_server/__init__.py").write_text("")
    return source


def test_install_switches_current_and_preserves_data(tmp_path):
    p = paths(tmp_path)
    p.config.parent.mkdir(parents=True)
    p.config.write_text('{"configured":true}')
    first = install_release(runtime_fixture(tmp_path, "one"), "1.0.0", p)
    second = install_release(runtime_fixture(tmp_path, "two"), "2.0.0", p)
    assert p.current.resolve() == second.release
    assert first.release.exists()
    assert json.loads(p.config.read_text())["configured"] is True


def test_failed_validation_keeps_previous_current(tmp_path):
    p = paths(tmp_path)
    first = install_release(runtime_fixture(tmp_path, "one"), "1.0.0", p)
    bad = tmp_path / "bad"
    bad.mkdir()
    with pytest.raises(ReleaseValidationError):
        install_release(bad, "2.0.0", p)
    assert p.current.resolve() == first.release


def test_launchagent_uses_stable_current_path(tmp_path):
    p = paths(tmp_path)
    plist = render_launchagent(p, Path("/usr/bin/python3"))
    assert "io.chorus.server" in plist
    assert str(p.current) in plist
    assert "com.voice-persona" not in plist


def test_launchagent_defaults_to_stable_runtime_venv(tmp_path):
    p = paths(tmp_path)
    assert str(p.runtime_dir / "venv/bin/python") in render_launchagent(p)


def test_same_version_reinstall_is_idempotent(tmp_path):
    p = paths(tmp_path)
    first = install_release(runtime_fixture(tmp_path, "one"), "1.0.0", p)
    marker = first.release / "installed.marker"
    marker.write_text("preserve")
    second = install_release(runtime_fixture(tmp_path, "one-copy"), "1.0.0", p)
    assert second.release == first.release
    assert marker.read_text() == "preserve"


def test_runtime_environment_installs_declared_requirements(tmp_path):
    p = paths(tmp_path)
    release = runtime_fixture(tmp_path, "deps")
    (release / "requirements.txt").write_text("fastapi==1.0\n")
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[1:3] == ["-m", "venv"]:
            python = p.runtime_dir / "venv/bin/python"
            python.parent.mkdir(parents=True)
            python.touch()
        return __import__("subprocess").CompletedProcess(command, 0)

    python = ensure_runtime_environment(p, release, run=run)
    assert python == p.runtime_dir / "venv/bin/python"
    assert any(any(str(item).endswith("requirements.txt") for item in command) for command in calls)


def test_uninstall_preserves_user_data_unless_purged(tmp_path):
    p = paths(tmp_path)
    p.runtime_dir.mkdir(parents=True)
    p.config.write_text('{"configured":true}')
    uninstall_runtime(p, home=tmp_path, run=lambda command, **kwargs: __import__("subprocess").CompletedProcess(command, 0))
    assert not p.runtime_dir.exists()
    assert p.config.exists()


@pytest.mark.parametrize(("name", "external", "tracking"), [("local", False, False), ("standard", True, False), ("detailed", True, True)])
def test_privacy_presets_are_explicit(tmp_path, name, external, tracking):
    p = paths(tmp_path)
    config = apply_privacy_preset(name, p.config)
    assert config["configured"] is True
    assert config["privacyPreset"] == name
    assert config["externalLlm"] is external
    assert config["usageTracking"] is tracking
