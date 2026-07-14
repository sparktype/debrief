import json
from pathlib import Path

import pytest

from hook_voice.runtime_manager import ReleaseValidationError, apply_privacy_preset, install_release, render_launchagent
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


@pytest.mark.parametrize(("name", "external", "tracking"), [("local", False, False), ("standard", True, False), ("detailed", True, True)])
def test_privacy_presets_are_explicit(tmp_path, name, external, tracking):
    p = paths(tmp_path)
    config = apply_privacy_preset(name, p.config)
    assert config["configured"] is True
    assert config["privacyPreset"] == name
    assert config["externalLlm"] is external
    assert config["usageTracking"] is tracking
