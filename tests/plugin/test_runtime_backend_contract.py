from pathlib import Path


def test_runtime_uses_installable_official_supertonic_backend():
    requirements = Path("runtime-requirements.txt").read_text()
    server = Path("tts_server/server.py").read_text()
    assert "supertonic[serve]" in requirements
    assert "supertonic-mlx" not in requirements
    assert "from supertonic import TTS" in server
    assert "from supertonic_mlx" not in server


def test_fresh_runtime_allows_model_download():
    server = Path("tts_server/server.py").read_text()
    assert 'os.environ["HF_HUB_OFFLINE"] = "1"' not in server
    assert "TTS(auto_download=True)" in server
