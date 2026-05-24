# tests/test_config.py
import json
import pytest
from pathlib import Path
from hook_voice.config import Config, load_config

def test_load_config_returns_defaults_when_no_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.auto_speak is True
    assert cfg.min_chars == 50
    assert cfg.voice == "Sohee"
    assert cfg.summary_model == "gpt-5.4"
    assert cfg.tts_speed == 1.2
    assert cfg.tts_instruct == "밝고 활기차게 말해주세요"
    assert cfg.skill_cooldown_minutes == 30
    assert cfg.supertonic_port == 7788
    assert cfg.edge_timeout_ms == 10000
    assert cfg.supertonic_timeout_ms == 20000

def test_load_config_merges_file_values(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({"autoSpeak": False, "minChars": 100, "ttsSpeed": 1.5}))
    cfg = load_config(cfg_file)
    assert cfg.auto_speak is False
    assert cfg.min_chars == 100
    assert cfg.tts_speed == 1.5
    assert cfg.voice == "Sohee"  # 기본값 유지

def test_load_config_returns_defaults_on_invalid_json(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text("not json{{")
    cfg = load_config(cfg_file)
    assert cfg.auto_speak is True

def test_load_config_all_keys_mapped(tmp_path):
    full = {
        "autoSpeak": False, "minChars": 99, "voice": "Eric",
        "summaryModel": "gpt-4", "ttsSpeed": 0.9, "ttsInstruct": "천천히",
        "skillCooldownMinutes": 10, "supertonicPort": 8888,
        "edgeTimeoutMs": 5000, "supertonicTimeoutMs": 15000,
    }
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps(full))
    cfg = load_config(cfg_file)
    assert cfg.auto_speak is False
    assert cfg.min_chars == 99
    assert cfg.voice == "Eric"
    assert cfg.summary_model == "gpt-4"
    assert cfg.tts_speed == 0.9
    assert cfg.tts_instruct == "천천히"
    assert cfg.skill_cooldown_minutes == 10
    assert cfg.supertonic_port == 8888
    assert cfg.edge_timeout_ms == 5000
    assert cfg.supertonic_timeout_ms == 15000
