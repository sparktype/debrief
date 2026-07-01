# hook_voice/speech_listener.py
# 마이크 녹음 → mlx-whisper 전사 → 클립보드 붙여넣기 상태 기계
import asyncio
import logging
import subprocess
import threading
from typing import Literal

import numpy as np

from .config import SttConfig

_log = logging.getLogger(__name__)

_VAD_RMS_THRESHOLD = 0.01  # VAD 발화 감지 RMS 임계값


class SpeechListener:
    def __init__(self, config: SttConfig) -> None:
        self._config = config
        self.state: Literal["idle", "recording"] = "idle"
        self._buffer: list[np.ndarray] = []
        self._stream = None
        self._lock = asyncio.Lock()
        self._vad_fired: bool = False  # VAD interrupt 연속 기동 억제 플래그
        self._stt_cfg = config  # VAD 설정 접근용 별칭

    async def toggle(self) -> dict:
        async with self._lock:
            if self.state == "idle":
                return await self._start_recording()
            return await self._stop_recording()

    async def _start_recording(self) -> dict:
        import sounddevice as sd
        self._buffer = []
        self._vad_fired = False  # 새 녹음 세션마다 리셋
        try:
            self._stream = sd.InputStream(
                samplerate=self._config.sample_rate,
                channels=1,
                dtype="float32",
                callback=self._audio_callback,
            )
            self._stream.start()
            self.state = "recording"
            _log.info("[STT] 녹음 시작")
            return {"state": "recording", "text": None}
        except Exception as e:
            _log.error("[STT] 마이크 오류: %s", e)
            return {"state": "idle", "error": "no_mic", "text": None}

    async def _stop_recording(self) -> dict:
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception as e:
                _log.error("[STT] 스트림 종료 오류: %s", e)
            finally:
                self._stream = None
        self.state = "idle"

        if not self._buffer:
            _log.info("[STT] 버퍼 비어있음 — 무시")
            return {"state": "idle", "text": None}

        audio = np.concatenate(self._buffer, axis=0).flatten()
        duration = len(audio) / self._config.sample_rate
        if duration < 1.0:
            _log.info("[STT] 녹음 너무 짧음 (%.2fs) — 무시", duration)
            return {"state": "idle", "text": None}

        try:
            loop = asyncio.get_running_loop()
            text = await loop.run_in_executor(None, self._transcribe, audio)
        except Exception as e:
            _log.error("[STT] 전사 실패: %s", e)
            return {"state": "idle", "error": "transcribe_failed", "text": None}

        try:
            if text:
                await loop.run_in_executor(None, self._type_text, text)
            _log.info("[STT] 전사 완료: %s", text[:40] if text else "(빈 결과)")
            return {"state": "idle", "text": text}
        except Exception as e:
            _log.error("[STT] 텍스트 주입 실패: %s", e)
            return {"state": "idle", "error": "type_failed", "text": text}

    def _audio_callback(self, indata: np.ndarray, frames: int, time, status) -> None:
        if status:
            _log.warning("[STT] 오디오 콜백 상태: %s", status)
        self._buffer.append(indata.copy())
        if self._stt_cfg.vad_interrupt and not self._vad_fired:
            rms = float(np.sqrt(np.mean(indata ** 2)))
            if rms > _VAD_RMS_THRESHOLD:
                self._vad_fired = True  # 연속 기동 억제
                threading.Thread(
                    target=self._fire_interrupt,
                    daemon=True,
                ).start()

    def _fire_interrupt(self) -> None:
        """VAD 감지 시 TTS 중단 신호를 비동기로 전송한다."""
        try:
            import httpx
            httpx.post("http://localhost:7777/interrupt", timeout=1.0)
        except Exception:
            pass  # TTS 서버 오프라인 시 조용히 무시

    def _transcribe(self, audio: np.ndarray) -> str:
        import mlx_whisper
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._config.model,
            language=self._config.language,
        )
        return result.get("text", "").strip()

    def _type_text(self, text: str) -> None:
        subprocess.run(
            ["pbcopy"],
            input=text.encode("utf-8"),
            check=False,
        )
        subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to keystroke "v" using command down'],
            check=False,
        )

    async def run(self, shutdown: asyncio.Event) -> None:
        if not self._config.enabled:
            _log.info("[STT] 비활성화 (enabled=False)")
            await shutdown.wait()
            return
        _log.info("[STT] SpeechListener 준비 (model=%s)", self._config.model)
        await shutdown.wait()
