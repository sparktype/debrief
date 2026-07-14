from hook_voice.config import load_config


def test_unconfigured_defaults_have_no_side_effect_capabilities(tmp_path):
    config = load_config(tmp_path / "missing.json")
    assert config.configured is False
    assert config.auto_speak is False
    assert config.usage_tracking is False
    assert config.assistant_tts.enabled is False
    assert config.assistant_tts.failure_explain is False
    assert config.assistant_tts.prompt_advice is False
