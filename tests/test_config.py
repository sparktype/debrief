# tests/test_config.py
import json
import pytest
from pathlib import Path
from hook_voice.config import Config, load_config, SttConfig

def test_load_config_returns_defaults_when_no_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.auto_speak is True
    assert cfg.min_chars == 50
    assert cfg.voice == "Sohee"
    assert cfg.summary_model == "gemini-3.5-flash"
    assert cfg.tts_speed == 1.1
    assert cfg.tts_instruct == "밝고 활기차게 말해주세요"
    assert cfg.skill_cooldown_minutes == 30
    assert cfg.supertonic_port == 7788
    assert cfg.supertonic_timeout_ms == 20000
    assert cfg.allow_insecure_tls is True

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
        "supertonicTimeoutMs": 15000, "allowInsecureTls": False,
        "speechRetouch": False,
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
    assert cfg.supertonic_timeout_ms == 15000
    assert cfg.allow_insecure_tls is False
    assert cfg.speech_retouch is False


def test_load_config_normalizes_invalid_values(tmp_path, caplog):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({
        "minChars": -1,
        "ttsSpeed": 0,
        "supertonicPort": 70000,
        "allowInsecureTls": "yes",
        "grafana": {"interval": 1},
    }))

    cfg = load_config(cfg_file)

    assert cfg.min_chars == 50
    assert cfg.tts_speed == 1.1
    assert cfg.supertonic_port == 7788
    assert cfg.allow_insecure_tls is True
    assert cfg.grafana.interval == 30
    assert "잘못된 값" in caplog.text


def test_load_config_stt_defaults(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.stt.enabled is False
    assert cfg.stt.model == "mlx-community/whisper-small-mlx"
    assert cfg.stt.language == "ko"
    assert cfg.stt.sample_rate == 16000
    assert cfg.stt.announce is True

def test_load_config_stt_from_file(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({
        "stt": {
            "enabled": True,
            "model": "mlx-community/whisper-tiny-mlx",
            "language": "en",
            "sampleRate": 8000,
            "announce": False,
        }
    }))
    cfg = load_config(cfg_file)
    assert cfg.stt.enabled is True
    assert cfg.stt.model == "mlx-community/whisper-tiny-mlx"
    assert cfg.stt.language == "en"
    assert cfg.stt.sample_rate == 8000
    assert cfg.stt.announce is False

def test_load_config_voice_json_takes_priority(tmp_path, monkeypatch):
    voice_json = tmp_path / ".voice.json"
    persona_json = tmp_path / ".voice-persona.json"
    voice_json.write_text(json.dumps({"minChars": 10}))
    persona_json.write_text(json.dumps({"minChars": 99}))
    import hook_voice.config as cfg_mod
    monkeypatch.setattr(cfg_mod, "_VOICE_JSON", voice_json)
    monkeypatch.setattr(cfg_mod, "_VOICE_PERSONA_JSON", persona_json)
    cfg = load_config()  # 경로 미지정 — _find_default_config() 경유
    assert cfg.min_chars == 10


def test_load_config_speech_retouch_default():
    """speech_retouch 기본값은 True."""
    cfg = load_config(None)
    assert cfg.speech_retouch is True


def test_load_config_speech_retouch_from_file(tmp_path):
    """speechRetouch=false 설정 파일에서 올바르게 로드."""
    f = tmp_path / ".voice.json"
    f.write_text('{"speechRetouch": false}', encoding="utf-8")
    cfg = load_config(f)
    assert cfg.speech_retouch is False
