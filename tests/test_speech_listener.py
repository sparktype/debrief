# tests/test_speech_listener.py
# SpeechListener 상태 기계 및 에러 처리 테스트
import asyncio
import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from hook_voice.config import SttConfig
from hook_voice.speech_listener import SpeechListener


@pytest.fixture
def stt_config():
    return SttConfig(
        enabled=True,
        model="mlx-community/whisper-small-mlx",
        language="ko",
        sample_rate=16000,
        announce=False,
    )


@pytest.mark.asyncio
async def test_toggle_idle_to_recording(stt_config):
    listener = SpeechListener(stt_config)
    with patch("sounddevice.InputStream") as mock_cls:
        mock_stream = MagicMock()
        mock_cls.return_value = mock_stream
        result = await listener.toggle()
    assert result["state"] == "recording"
    assert listener.state == "recording"
    mock_stream.start.assert_called_once()


@pytest.mark.asyncio
async def test_toggle_recording_to_idle_short_buffer(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    # 100 샘플 = 0.006초 → 1초 미만 → 무시
    listener._buffer = [np.zeros((100, 1), dtype="float32")]
    listener._stream = MagicMock()
    result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("text") is None
    assert listener.state == "idle"


@pytest.mark.asyncio
async def test_toggle_recording_transcribes_long_buffer(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    # 32000 샘플 = 2초 → 전사 진행
    listener._buffer = [np.zeros((32000, 1), dtype="float32")]
    listener._stream = MagicMock()
    with patch.object(listener, "_transcribe", return_value="안녕하세요"), \
         patch.object(listener, "_type_text") as mock_type:
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result["text"] == "안녕하세요"
    mock_type.assert_called_once_with("안녕하세요")


@pytest.mark.asyncio
async def test_toggle_mic_error_returns_no_mic(stt_config):
    listener = SpeechListener(stt_config)
    with patch("sounddevice.InputStream", side_effect=Exception("PortAudioError: no device")):
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("error") == "no_mic"


@pytest.mark.asyncio
async def test_toggle_transcribe_error_returns_failed(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    listener._buffer = [np.zeros((32000, 1), dtype="float32")]
    listener._stream = MagicMock()
    with patch.object(listener, "_transcribe", side_effect=RuntimeError("model error")):
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("error") == "transcribe_failed"


@pytest.mark.asyncio
async def test_run_disabled_exits_on_shutdown(stt_config):
    stt_config.enabled = False
    listener = SpeechListener(stt_config)
    shutdown = asyncio.Event()
    shutdown.set()
    # enabled=False인 경우 shutdown 대기 후 반환 — 예외 없음
    await listener.run(shutdown)
