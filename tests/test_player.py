# tests/test_player.py
import asyncio
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from hook_voice.player import speak_hook, speak_agent, _enqueue_spool, _speed_to_wpm


def test_enqueue_spool_moves_file_and_encodes_speed(tmp_path):
    """_enqueue_spool이 파일을 이동하고 파일명에 speed를 인코딩한다."""
    src = tmp_path / "audio.mp3"
    src.write_bytes(b"fake mp3")
    spool = tmp_path / "spool"
    spool.mkdir()

    with patch("hook_voice.player.SPOOL_DIR", spool):
        _enqueue_spool(src, 1.2)

    mp3_files = list(spool.glob("*.mp3"))
    assert len(mp3_files) == 1
    assert "_120." in mp3_files[0].name
    assert not mp3_files[0].with_suffix(".meta").exists()
    assert not src.exists()


async def test_speak_hook_enqueues_via_edge(tmp_path, monkeypatch):
    mp3_src = tmp_path / "edge.mp3"
    mp3_src.write_bytes(b"fake")
    spool = tmp_path / "spool"
    spool.mkdir()

    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player._venv_python", lambda: Path("/usr/bin/python3"))
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    async def fake_generate_edge(text):
        mp3_src.write_bytes(b"fake")
        return mp3_src

    with patch("hook_voice.player._generate_edge", side_effect=fake_generate_edge):
        await speak_hook("안녕하세요", "Sohee", 1.2)

    assert len(list(spool.glob("*.mp3"))) == 1


async def test_speak_hook_falls_back_when_edge_fails(tmp_path, monkeypatch):
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player._venv_python", lambda: Path("/usr/bin/python3"))
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_edge", side_effect=Exception("EdgeTTS 실패")):
        with patch("hook_voice.player._speak_without_edge", new=AsyncMock()) as mock_fallback:
            await speak_hook("안녕", "Sohee", 1.2)
            mock_fallback.assert_called_once()


async def test_speak_agent_enqueues_supertonic(tmp_path, monkeypatch):
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock(return_value=True)):
        with patch("hook_voice.player._generate_supertonic", new=AsyncMock(return_value=b"RIFF....WAV")):
            await speak_agent("빌더입니다. 작업 완료", "M4", 7788, 1.2)

    wav_files = list(spool.glob("*.wav"))
    assert len(wav_files) == 1


async def test_speak_agent_passes_steps_to_generate(tmp_path, monkeypatch):
    """speak_agent가 steps 파라미터를 _generate_supertonic으로 전달한다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    mock_gen = AsyncMock(return_value=b"RIFF")
    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock(return_value=True)), \
         patch("hook_voice.player._generate_supertonic", new=mock_gen):
        await speak_agent("테스트 발화", "M2", 7788, 1.2, steps=10)

    mock_gen.assert_called_once()
    assert mock_gen.call_args.kwargs.get("steps") == 10


async def test_speak_agent_skips_empty_text():
    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock()) as mock:
        await speak_agent("", "M4", 7788, 1.2)
        mock.assert_not_called()


def test_speed_to_wpm_converts_multiplier():
    assert _speed_to_wpm(1.0) == 175
    assert _speed_to_wpm(1.2) == 210
    assert _speed_to_wpm(0.9) == 158


async def test_speak_subprocess_uses_macos_say_with_voice_and_speed(monkeypatch):
    played = []

    async def fake_exec(*args, **kwargs):
        played.append(args)
        proc = AsyncMock()
        proc.wait = AsyncMock(return_value=0)
        return proc

    monkeypatch.setattr("hook_voice.player._venv_python", lambda: Path("/nonexistent/python3"))

    with patch("hook_voice.player.asyncio.create_subprocess_exec", side_effect=fake_exec):
        from hook_voice.player import _speak_subprocess
        await _speak_subprocess("hello", "Yuna", 1.2)

    assert played == [("say", "-r", "210", "-v", "Yuna", "hello")]


async def test_speak_without_edge_falls_back_on_http_429(monkeypatch):
    monkeypatch.setattr("hook_voice.player._is_tts_server_alive", AsyncMock(return_value=True))
    monkeypatch.setattr("hook_voice.player._speak_http", AsyncMock(return_value=False))
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._speak_subprocess", new=AsyncMock()) as mock_subprocess:
        from hook_voice.player import _speak_without_edge
        await _speak_without_edge("안녕", "Sohee", 1.2)
        mock_subprocess.assert_called_once()


async def test_generate_supertonic_uses_native_api():
    """_generate_supertonic이 /v1/tts (Native API)를 호출하고 steps 파라미터를 포함한다."""
    from hook_voice.player import _generate_supertonic

    captured = {}

    class FakeResponse:
        status_code = 200
        content = b"RIFF_WAV"
        def raise_for_status(self): pass

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass
        async def post(self, url, json=None, timeout=None):
            captured["url"] = url
            captured["json"] = json
            return FakeResponse()

    with patch("hook_voice.player.httpx.AsyncClient", return_value=FakeClient()):
        result = await _generate_supertonic("안녕하세요", "M4", 7788, steps=10)

    assert result == b"RIFF_WAV"
    assert "/v1/tts" in captured["url"], f"Expected /v1/tts URL, got: {captured['url']}"
    assert captured["json"]["text"] == "안녕하세요"
    assert captured["json"]["steps"] == 10
    assert "input" not in captured["json"], "input 키는 Native API에 없어야 함"
    assert "model" not in captured["json"], "model 키는 Native API에 없어야 함"


from hook_voice.observability.circuit_breaker import _breakers, CBState


@pytest.fixture(autouse=True)
def reset_cbs():
    yield
    for cb in list(_breakers.values()):
        cb.reset()
    _breakers.clear()


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_opens_after_failures(monkeypatch, tmp_path):
    """EdgeTTS가 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice import player as _player
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["edge_tts"] = CircuitBreaker("edge_tts", CircuitBreakerConfig(failure_threshold=3))

    call_count = 0

    async def fail_edge(text):
        nonlocal call_count
        call_count += 1
        raise OSError("edge fail")

    monkeypatch.setattr(_player, "_generate_edge", fail_edge)
    monkeypatch.setattr(_player, "_venv_python", lambda: tmp_path / "python3")
    (tmp_path / "python3").touch()
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())
    monkeypatch.delenv("VOICE_PERSONA_OFFLINE", raising=False)

    for _ in range(3):
        await _player.speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)

    assert _breakers["edge_tts"].state == CBState.OPEN


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_open_skips_generate(monkeypatch, tmp_path):
    """EdgeTTS CB가 OPEN 상태이면 _generate_edge를 호출하지 않는다."""
    import time
    from hook_voice import player as _player
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig, CBState

    cb = CircuitBreaker("edge_tts", CircuitBreakerConfig(failure_threshold=3, recovery_timeout=60.0))
    cb._state = CBState.OPEN
    cb._opened_at = time.time()
    _breakers["edge_tts"] = cb

    called = []

    async def should_not_be_called(text):
        called.append(text)
        raise RuntimeError("should not be called")

    monkeypatch.setattr(_player, "_generate_edge", should_not_be_called)
    monkeypatch.setattr(_player, "_venv_python", lambda: tmp_path / "python3")
    (tmp_path / "python3").touch()
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())
    monkeypatch.delenv("VOICE_PERSONA_OFFLINE", raising=False)

    await _player.speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)
    assert called == []


@pytest.mark.asyncio
async def test_speak_agent_supertonic_cb_opens_after_failures(monkeypatch):
    """Supertonic이 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice import player as _player
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["supertonic"] = CircuitBreaker("supertonic", CircuitBreakerConfig(failure_threshold=3))

    monkeypatch.setattr(_player, "_is_supertonic_alive", AsyncMock(return_value=True))

    async def fail_st(*args, **kwargs):
        raise OSError("supertonic fail")

    monkeypatch.setattr(_player, "_generate_supertonic", fail_st)
    monkeypatch.setattr(_player, "_speak_without_edge", AsyncMock())

    for _ in range(3):
        await _player.speak_agent("test", "M2", port=7788, speed=1.0)

    assert _breakers["supertonic"].state == CBState.OPEN


from hook_voice.player import SPOOL_DIR
import hook_voice.player as player_module

def test_enqueue_spool_encodes_speed_in_filename(tmp_path):
    """_enqueue_spool이 meta 파일 대신 파일명에 speed를 인코딩한다."""
    # Temporarily override SPOOL_DIR
    original_spool = player_module.SPOOL_DIR
    player_module.SPOOL_DIR = tmp_path
    try:
        audio = tmp_path / "source.wav"
        audio.write_bytes(b"RIFF")

        from hook_voice.player import _enqueue_spool
        _enqueue_spool(audio, speed=1.25)

        spool_files = list(tmp_path.glob("*.wav"))
        meta_files = list(tmp_path.glob("*.meta"))

        assert len(spool_files) == 1, f"Expected 1 wav, got: {spool_files}"
        assert len(meta_files) == 0, f"Expected 0 meta files, got: {meta_files}"
        assert "_125." in spool_files[0].name, f"Expected _125. in filename, got: {spool_files[0].name}"
    finally:
        player_module.SPOOL_DIR = original_spool
