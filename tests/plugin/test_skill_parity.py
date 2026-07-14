from pathlib import Path

import pytest


ROOT = Path("plugins/chorus/skills")
EXPECTED = {"setup", "status", "doctor", "mute", "listen", "mode", "digest"}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_skill_has_valid_contract(name):
    path = ROOT / name / "SKILL.md"
    body = path.read_text()
    assert body.startswith("---\n")
    assert f"name: chorus-{name}" in body
    assert "description: Use when" in body
    assert "chorus-runtime" in body
    assert ".venv/bin/python" not in body
    assert "/Users/" not in body


def test_plugin_exposes_exact_shared_skill_set():
    assert {path.parent.name for path in ROOT.glob("*/SKILL.md")} == EXPECTED


def test_runtime_manager_exposes_every_skill_command():
    body = Path("hook_voice/runtime_manager.py").read_text()
    for name in EXPECTED:
        assert f'"{name}"' in body
