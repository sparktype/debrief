# tests/test_player.py
import pytest
import time
from pathlib import Path
from unittest.mock import AsyncMock, patch

import hook_voice.player as player_module
from hook_voice.player import speak_hook, speak_agent, _enqueue_spool, _dynamic_steps
from hook_voice.observability.circuit_breaker import _breakers, CBState


@pytest.fixture(autouse=True)
def reset_cbs():
    yield
    for cb in list(_breakers.values()):
        cb.reset()
    _breakers.clear()


# ── _enqueue_spool ───────────────────────────────────────────────────────────

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
    assert not src.exists()


def test_enqueue_spool_encodes_speed_125(tmp_path):
    """speed=1.25 → 파일명에 _125. 인코딩."""
    original = player_module.SPOOL_DIR
    player_module.SPOOL_DIR = tmp_path
    try:
        src = tmp_path / "source.wav"
        src.write_bytes(b"RIFF")
        _enqueue_spool(src, 1.25)
        files = list(tmp_path.glob("*.wav"))
        assert len(files) == 1
        assert "_125." in files[0].name
        assert len(list(tmp_path.glob("*.meta"))) == 0
    finally:
        player_module.SPOOL_DIR = original


# ── _dynamic_steps ───────────────────────────────────────────────────────────

def test_dynamic_steps_short_text_capped_at_8():
    assert _dynamic_steps("짧은 텍스트", base_steps=12) == 8


def test_dynamic_steps_long_text_returns_base():
    long = "가" * 110
    assert _dynamic_steps(long, base_steps=10) == 10


# ── speak_hook ───────────────────────────────────────────────────────────────

async def test_speak_hook_enqueues_wav(tmp_path, monkeypatch):
    """speak_hook이 supertonic으로 WAV를 생성해 spool에 저장한다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", new=AsyncMock(return_value=b"RIFF_WAV")):
        await speak_hook("안녕하세요", 1.2)

    assert len(list(spool.glob("*.wav"))) == 1


async def test_speak_hook_logs_warning_on_failure(tmp_path, monkeypatch, caplog):
    """supertonic 실패 시 예외를 전파하지 않고 경고 로그를 남긴다."""
    import logging
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", tmp_path)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", side_effect=Exception("TTS 실패")):
        with caplog.at_level(logging.WARNING, logger="hook_voice.player"):
            await speak_hook("안녕", 1.2)

    assert any("Hook TTS" in r.message for r in caplog.records)


# ── speak_agent ──────────────────────────────────────────────────────────────

async def test_speak_agent_enqueues_wav(tmp_path, monkeypatch):
    """Supertonic 성공 시 wav 파일이 spool에 저장된다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", new=AsyncMock(return_value=b"RIFF....WAV")):
        await speak_agent("빌더입니다. 작업 완료", "M4", 7788, 1.2)

    assert len(list(spool.glob("*.wav"))) == 1


async def test_speak_agent_passes_adjusted_steps(tmp_path, monkeypatch):
    """speak_agent가 _dynamic_steps로 조정된 steps를 전달한다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    long_text = "가" * 110
    mock_gen = AsyncMock(return_value=b"RIFF")
    with patch("hook_voice.player._generate_supertonic", new=mock_gen):
        await speak_agent(long_text, "M2", 7788, 1.2, steps=10)

    assert mock_gen.call_args.kwargs.get("steps") == 10


async def test_speak_agent_skips_empty_text():
    """빈 텍스트는 _generate_supertonic을 호출하지 않는다."""
    mock_gen = AsyncMock()
    with patch("hook_voice.player._generate_supertonic", new=mock_gen):
        await speak_agent("", "M4", 7788, 1.2)
    mock_gen.assert_not_called()


async def test_speak_agent_logs_on_failure(monkeypatch, caplog):
    """Supertonic 실패 시 예외를 전파하지 않고 경고 로그를 남긴다."""
    import logging
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", side_effect=Exception("ST 실패")):
        with caplog.at_level(logging.WARNING, logger="hook_voice.player"):
            await speak_agent("테스트", "M2", 7788, 1.0)

    assert any("Supertonic" in r.message for r in caplog.records)


# ── _generate_supertonic ─────────────────────────────────────────────────────

async def test_generate_supertonic_posts_to_v1_tts():
    """_generate_supertonic이 /v1/tts에 steps를 포함해 POST한다."""
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
    assert "/v1/tts" in captured["url"]
    assert captured["json"]["steps"] == 10
    assert captured["json"]["voice"] == "M4"


# ── Circuit Breaker ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_speak_hook_edge_cb_opens_after_failures(monkeypatch, tmp_path):
    """supertonic_hook이 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["supertonic_hook"] = CircuitBreaker("supertonic_hook", CircuitBreakerConfig(failure_threshold=3))

    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)
    monkeypatch.setattr(player_module, "SPOOL_DIR", tmp_path)

    async def fail_st(*args, **kwargs):
        raise OSError("supertonic fail")

    monkeypatch.setattr(player_module, "_generate_supertonic", fail_st)

    for _ in range(3):
        await speak_hook("test", speed=1.0)

    assert _breakers["supertonic_hook"].state == CBState.OPEN


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_open_skips_generate(monkeypatch, tmp_path):
    """supertonic_hook CB가 OPEN이면 _generate_supertonic을 호출하지 않는다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig, CBState as _CBState

    cb = CircuitBreaker("supertonic_hook", CircuitBreakerConfig(failure_threshold=3, recovery_timeout=60.0))
    cb._state = _CBState.OPEN
    cb._opened_at = time.time()
    _breakers["supertonic_hook"] = cb

    called = []

    async def should_not_be_called(*args, **kwargs):
        called.append(args)

    monkeypatch.setattr(player_module, "_generate_supertonic", should_not_be_called)
    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)
    monkeypatch.setattr(player_module, "SPOOL_DIR", tmp_path)

    await speak_hook("test", speed=1.0)
    assert called == []


@pytest.mark.asyncio
async def test_speak_agent_supertonic_cb_opens_after_failures(monkeypatch):
    """Supertonic이 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["supertonic"] = CircuitBreaker("supertonic", CircuitBreakerConfig(failure_threshold=3))

    async def fail_st(*args, **kwargs):
        raise OSError("supertonic fail")

    monkeypatch.setattr(player_module, "_generate_supertonic", fail_st)
    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)

    for _ in range(3):
        await speak_agent("test", "M2", port=7788, speed=1.0)

    assert _breakers["supertonic"].state == CBState.OPEN
