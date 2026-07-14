from pathlib import Path


def test_readme_is_plugin_first_and_privacy_explicit():
    readme = Path("README.md").read_text()
    assert readme.index("플러그인 설치") < readme.index("레거시")
    for text in ("/chorus:setup", "/chorus:status", "/chorus:doctor", "/hooks", "local", "standard", "detailed"):
        assert text in readme
    assert "별도 설정 없이 바로 작동" not in readme
    assert "assistantTts.enabled: true`(기본값)" not in readme


def test_onboarding_covers_both_agents_and_safe_defaults():
    body = Path("ONBOARDING.md").read_text()
    assert "Claude Code" in body and "Codex" in body
    assert "autoSpeak=false" in body
    assert "usageTracking=false" in body
    assert "externalLlm=false" in body


def test_migration_doc_explains_preserve_and_purge():
    body = Path("docs/plugin-migration.md").read_text()
    assert "io.chorus.server" in body
    assert "com.voice-persona.tts-server" in body
    assert "--purge" in body
    assert "preserve" in body.lower() or "보존" in body
