# tests/test_voice_router.py
import json
import pytest
from pathlib import Path
from hook_voice.voice_router import _FALLBACK_MAP, load_voice_map, resolve_voice, resolve_voice_name, get_agent_label

_SAMPLE_MAP = {
    "supertonic": {"lang": "ko"},
    "voices": {"reviewer": "M2", "planner": "M1", "default": "F1"},
    "categories": {
        "reviewer": ["code-reviewer", "feature-reviewer"],
        "planner": ["planner", "architect"],
    },
}

def test_load_voice_map_returns_fallback_when_no_file(tmp_path):
    vm = load_voice_map(tmp_path / "nonexistent.json")
    assert vm["voices"]["default"] == "F1"

def test_load_voice_map_parses_file(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert vm["voices"]["reviewer"] == "M2"

def test_resolve_voice_matches_category(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert resolve_voice("code-reviewer", vm) == "M2"
    assert resolve_voice("planner", vm) == "M1"

def test_resolve_voice_returns_default_for_unknown(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert resolve_voice("unknown-agent", vm) == "F1"

def test_get_agent_label_known(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert get_agent_label("code-reviewer", vm) == "리뷰어"
    assert get_agent_label("planner", vm) == "플래너"

def test_get_agent_label_unknown(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert get_agent_label("unknown-bot", vm) == "에이전트"

def test_fallback_map_f1_is_yeona():
    """voice-map.json 로드 실패 시 F1 이름이 '연아'여야 한다."""
    assert _FALLBACK_MAP["voice_names"]["F1"] == "연아"

def test_resolve_voice_name_fallback_uses_yeona(tmp_path):
    """voice-map.json이 없을 때 default voice 이름이 '연아'."""
    vm = load_voice_map(tmp_path / "nonexistent.json")
    name = resolve_voice_name("unknown-agent", vm)
    assert name == "연아"
