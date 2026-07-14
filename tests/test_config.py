# tests/test_config.py
import json
import pytest
from pathlib import Path
from hook_voice.config import Config, load_config, SttConfig

def test_load_config_returns_defaults_when_no_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.configured is False
    assert cfg.auto_speak is False
    assert cfg.min_chars == 50
    assert cfg.voice == "Sohee"
    assert cfg.summary_model == "gemini-3.5-flash"
    assert cfg.tts_speed == 1.1
    assert cfg.tts_instruct == "밝고 활기차게 말해주세요"
    assert cfg.skill_cooldown_minutes == 30
    assert cfg.supertonic_port == 7777
    assert cfg.supertonic_timeout_ms == 20000
    assert cfg.allow_insecure_tls is True
    assert cfg.voice_mode == "normal"

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
    assert cfg.auto_speak is False

def test_load_config_all_keys_mapped(tmp_path):
    full = {
        "autoSpeak": False, "minChars": 99, "voice": "Eric",
        "summaryModel": "gpt-4", "ttsSpeed": 0.9, "ttsInstruct": "천천히",
        "skillCooldownMinutes": 10, "supertonicPort": 8888,
        "supertonicTimeoutMs": 15000, "allowInsecureTls": False,
        "speechRetouch": False, "voiceMode": "focus",
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
    assert cfg.voice_mode == "focus"


def test_load_config_normalizes_invalid_values(tmp_path, caplog):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({
        "minChars": -1,
        "ttsSpeed": 0,
        "supertonicPort": 70000,
        "allowInsecureTls": "yes",
        "voiceMode": "",
    }))

    cfg = load_config(cfg_file)

    assert cfg.min_chars == 50
    assert cfg.tts_speed == 1.1
    assert cfg.supertonic_port == 7777
    assert cfg.allow_insecure_tls is True
    assert cfg.voice_mode == "normal"
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


def test_stable_runtime_config_takes_priority_over_checkout_config(tmp_path, monkeypatch):
    stable = tmp_path / ".local/share/chorus/config.json"
    stable.parent.mkdir(parents=True)
    stable.write_text(json.dumps({"configured": True, "autoSpeak": False, "minChars": 7}))
    checkout = tmp_path / ".voice.json"
    checkout.write_text(json.dumps({"minChars": 99}))
    import hook_voice.config as cfg_mod
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(cfg_mod, "_VOICE_JSON", checkout)
    assert load_config().min_chars == 7


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


def test_load_config_bridge_defaults():
    """bridge_enabled 기본값은 False, bridge_threshold_ms 기본값은 500."""
    cfg = Config()
    assert cfg.bridge_enabled is False
    assert cfg.bridge_threshold_ms == 500


def test_load_config_bridge_enabled_from_file(tmp_path):
    """bridgeEnabled=true 설정 파일에서 올바르게 로드."""
    f = tmp_path / ".voice.json"
    f.write_text('{"bridgeEnabled": true, "bridgeThresholdMs": 300}', encoding="utf-8")
    cfg = load_config(f)
    assert cfg.bridge_enabled is True
    assert cfg.bridge_threshold_ms == 300


def test_load_config_bridge_enabled_normalizes_invalid(tmp_path, caplog):
    """bridgeEnabled에 비불리언 값이 오면 기본값으로 복원한다."""
    f = tmp_path / ".voice.json"
    f.write_text('{"bridgeEnabled": "yes", "bridgeThresholdMs": -1}', encoding="utf-8")
    cfg = load_config(f)
    assert cfg.bridge_enabled is False
    assert cfg.bridge_threshold_ms == 500
    assert "잘못된 값" in caplog.text


def test_usage_tracking_default_false():
    """설정 전에는 사용 통계를 기록하지 않는다."""
    from hook_voice.config import Config
    cfg = Config()
    assert cfg.usage_tracking is False


def test_load_config_usage_tracking_false(tmp_path):
    """.voice.json에서 usageTracking: false를 파싱한다."""
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text('{"usageTracking": false}', encoding="utf-8")
    cfg = load_config(cfg_file)
    assert cfg.usage_tracking is False


def test_load_config_usage_tracking_invalid(tmp_path):
    """usageTracking에 비-bool 값이 오면 안전한 기본값 False로 복원한다."""
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text('{"usageTracking": "yes"}', encoding="utf-8")
    cfg = load_config(cfg_file)
    assert cfg.usage_tracking is False
