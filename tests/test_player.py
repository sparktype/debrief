# tests/test_player.py
import asyncio
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from hook_voice.player import speak_hook, speak_agent, _enqueue_spool


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


async def test_speak_agent_skips_empty_text():
    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock()) as mock:
        await speak_agent("", "M4", 7788, 1.2)
        mock.assert_not_called()


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
