import json

import pytest

from hook_voice.runtime_manager import PRESETS, apply_privacy_preset, import_legacy_config
from hook_voice.runtime_paths import RuntimePaths


@pytest.mark.parametrize(("name", "assistant", "tracking", "tool_events"), [
    ("local", False, False, "failures"),
    ("standard", True, False, "failures"),
    ("detailed", True, True, "build_test_risk_failure"),
])
def test_setup_presets_have_exact_capabilities(tmp_path, name, assistant, tracking, tool_events):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    value = apply_privacy_preset(name, paths.config)
    assert value["assistantTts"]["enabled"] is assistant
    assert value["usageTracking"] is tracking
    assert value["toolEventSpeech"] == tool_events


def test_legacy_import_never_reenables_disabled_capability(tmp_path):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    legacy = tmp_path / ".voice.json"
    legacy.write_text(json.dumps({"autoSpeak": False, "usageTracking": False, "assistantTts": {"enabled": False}, "voice": "F2"}))
    value = import_legacy_config(legacy, paths.config, "detailed")
    assert value["autoSpeak"] is False
    assert value["usageTracking"] is False
    assert value["externalLlm"] is False
    assert value["voice"] == "F2"
    assert value["migration"]["importedLegacy"] is True
