# supertonic MLX spool enqueue — speak_hook / speak_agent
import asyncio
import logging
import os
import random
import shutil as _shutil
import string
import tempfile
import time
from pathlib import Path

import httpx

from .delivery.priority_spool import enqueue_with_priority as _enqueue_priority
from .last_message import save_last_message
from .observability.circuit_breaker import get_circuit_breaker
from .summarizer import chunk_for_tts

_log = logging.getLogger(__name__)

SPOOL_DIR = Path("/tmp/tts-spool")
HOOK_VOICE = "F1"        # 메인 응답 목소리 — F1 연아 (calm, slightly low)
HOOK_STEPS = 8
HOOK_SYNTH_SPEED = 0.93


def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)


async def _generate_supertonic(
    text: str, voice: str, port: int, steps: int = 12, timeout: float = 20.0,
    synth_speed: float = 1.05,
) -> bytes:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"http://localhost:{port}/v1/tts",
            json={"text": text, "voice": voice, "lang": "ko",
                  "steps": steps, "speed": synth_speed, "response_format": "wav"},
            timeout=timeout,
        )
        r.raise_for_status()
        return r.content


def _dynamic_steps(text: str, base_steps: int) -> int:
    """텍스트 길이에 따라 diffusion steps 동적 조정 — 100자 미만이면 최소 8 steps."""
    return min(8, base_steps) if len(text) < 100 else base_steps


async def speak_hook(text: str, speed: float = 1.2,
                     hook_timeout: float = 20.0, priority: str = "NORMAL") -> None:
    """메인 Claude 응답을 supertonic F1(연아) 목소리로 발화한다."""
    hook_cb = get_circuit_breaker("supertonic_hook")

    async def _st_call() -> bytes:
        return await asyncio.wait_for(
            _generate_supertonic(
                text, voice=HOOK_VOICE, port=7777,
                steps=HOOK_STEPS, timeout=hook_timeout,
                synth_speed=HOOK_SYNTH_SPEED,
            ),
            timeout=hook_timeout,
        )

    try:
        wav_bytes = await hook_cb.call(_st_call, fallback=None)
        if wav_bytes is not None:
            fd, tmp_str = tempfile.mkstemp(suffix=".wav", prefix="vp_hook_")
            tmp = Path(tmp_str)
            try:
                os.close(fd)
                tmp.write_bytes(wav_bytes)
                _enqueue_priority(tmp, speed=speed, priority=priority, spool_dir=SPOOL_DIR)
                tmp = None  # enqueue가 rename/copy 완료 — 정리 불필요
            finally:
                if tmp is not None and tmp.exists():
                    tmp.unlink(missing_ok=True)
            save_last_message(text)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        _log.warning("Hook TTS 생성 실패: %s", type(e).__name__)


async def speak_agent(text: str, voice: str, port: int, speed: float, instruct: str = "",
                      steps: int = 12, supertonic_timeout: float = 20.0,
                      synth_speed: float = 1.05) -> None:
    if not text.strip():
        return
    actual_steps = _dynamic_steps(text, steps)
    st_cb = get_circuit_breaker("supertonic")

    async def _st_call() -> bytes:
        return await asyncio.wait_for(
            _generate_supertonic(
                text, voice, port, steps=actual_steps,
                timeout=supertonic_timeout, synth_speed=synth_speed,
            ),
            timeout=supertonic_timeout,
        )

    try:
        wav_bytes = await st_cb.call(_st_call, fallback=None)
        if wav_bytes is not None:
            fd, tmp_str = tempfile.mkstemp(suffix=".wav", prefix="vp_st_")
            tmp = Path(tmp_str)
            try:
                os.close(fd)
                tmp.write_bytes(wav_bytes)
                _enqueue_priority(tmp, speed=speed, priority="NORMAL", spool_dir=SPOOL_DIR)
                tmp = None
            finally:
                if tmp is not None and tmp.exists():
                    tmp.unlink(missing_ok=True)
            save_last_message(text)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        _log.warning("Supertonic 생성 실패: %s", type(e).__name__)


def enqueue_earcon(earcon_path: Path, speed: float = 1.0) -> None:
    """사전 렌더링된 earcon WAV 파일을 spool 디렉토리에 enqueue한다."""
    if not earcon_path.exists():
        _log.warning("earcon 파일 없음: %s", earcon_path)
        return
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))
    dest = SPOOL_DIR / f"{uid}_{speed_tag}.wav"
    _shutil.copy2(earcon_path, dest)


async def speak_hook_chunked(
    text: str,
    speed: float = 1.2,
    hook_timeout: float = 20.0,
    max_chars: int = 80,
) -> None:
    """텍스트를 문장 단위로 분할하여 순차적으로 TTS 스풀에 넣는다.

    긴 텍스트에서 TTS 엔진의 잘림 현상을 방지한다.
    """
    chunks = chunk_for_tts(text, max_chars=max_chars)
    for chunk in chunks:
        await speak_hook(chunk, speed=speed, hook_timeout=hook_timeout)
