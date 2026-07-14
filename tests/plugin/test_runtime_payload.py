from pathlib import Path


def test_runtime_payload_contains_required_packages():
    assert Path("plugins/chorus/runtime/hook_voice/__init__.py").exists()
    assert Path("plugins/chorus/runtime/tts_server/__init__.py").exists()
    assert Path("plugins/chorus/runtime/assets/bridge_thinking.wav").exists()


def test_runtime_payload_excludes_caches_and_credentials():
    paths = [str(path) for path in Path("plugins/chorus/runtime").rglob("*")]
    assert not any("__pycache__" in path for path in paths)
    assert not any(".venv" in path for path in paths)
    assert not Path("plugins/chorus/runtime/.voice.json").exists()
