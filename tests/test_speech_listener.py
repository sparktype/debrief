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


def test_stt_config_vad_interrupt_default():
    """vad_interrupt 기본값은 False다."""
    from hook_voice.config import SttConfig
    stt = SttConfig()
    assert stt.vad_interrupt is False


def test_stt_config_vad_interrupt_enabled():
    """vad_interrupt를 True로 설정할 수 있다."""
    from hook_voice.config import SttConfig
    stt = SttConfig(vad_interrupt=True)
    assert stt.vad_interrupt is True


def test_load_config_stt_vad_interrupt_parsed(tmp_path):
    """vadInterrupt 키가 .voice.json에서 올바르게 파싱된다."""
    import json
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text(json.dumps({"stt": {"vadInterrupt": True}}), encoding="utf-8")
    cfg = load_config(cfg_file)
    assert cfg.stt.vad_interrupt is True


def test_load_config_stt_vad_interrupt_default_false(tmp_path):
    """vadInterrupt 미설정 시 기본값 False다."""
    import json
    from hook_voice.config import load_config
    cfg_file = tmp_path / ".voice.json"
    cfg_file.write_text(json.dumps({"stt": {"enabled": True}}), encoding="utf-8")
    cfg = load_config(cfg_file)
    assert cfg.stt.vad_interrupt is False


def test_audio_callback_fires_interrupt_when_vad_enabled():
    """vad_interrupt=True이고 RMS 임계값 초과 시 _fire_interrupt가 호출된다."""
    stt_cfg = SttConfig(enabled=True, vad_interrupt=True)
    listener = SpeechListener(stt_cfg)
    high_rms_audio = np.ones((512, 1), dtype="float32") * 0.5  # RMS >> 0.01
    with patch.object(listener, "_fire_interrupt") as mock_fire, \
         patch("threading.Thread") as mock_thread:
        mock_thread_instance = MagicMock()
        mock_thread.return_value = mock_thread_instance
        listener._audio_callback(high_rms_audio, 512, None, None)
        mock_thread.assert_called_once()
        mock_thread_instance.start.assert_called_once()


def test_audio_callback_no_interrupt_when_vad_disabled():
    """vad_interrupt=False이면 임계값 초과해도 스레드를 생성하지 않는다."""
    stt_cfg = SttConfig(enabled=True, vad_interrupt=False)
    listener = SpeechListener(stt_cfg)
    high_rms_audio = np.ones((512, 1), dtype="float32") * 0.5
    with patch("threading.Thread") as mock_thread:
        listener._audio_callback(high_rms_audio, 512, None, None)
        mock_thread.assert_not_called()


def test_audio_callback_no_interrupt_when_rms_below_threshold():
    """vad_interrupt=True이더라도 RMS가 임계값 미만이면 스레드를 생성하지 않는다."""
    stt_cfg = SttConfig(enabled=True, vad_interrupt=True)
    listener = SpeechListener(stt_cfg)
    low_rms_audio = np.zeros((512, 1), dtype="float32")  # RMS = 0.0
    with patch("threading.Thread") as mock_thread:
        listener._audio_callback(low_rms_audio, 512, None, None)
        mock_thread.assert_not_called()


def test_fire_interrupt_silent_on_http_error():
    """_fire_interrupt는 HTTP 오류 시 예외를 전파하지 않는다."""
    stt_cfg = SttConfig(enabled=True, vad_interrupt=True)
    listener = SpeechListener(stt_cfg)
    with patch("httpx.post", side_effect=Exception("connection refused")):
        listener._fire_interrupt()  # 예외 없이 통과해야 함
