# EdgeTTS spool enqueue, speak_hook / speak_agent
import asyncio
import logging
import random
import ssl
import string
import tempfile
import time
from pathlib import Path

import edge_tts
import edge_tts.communicate as _ec
import httpx

from .last_message import save_last_message
from .observability.circuit_breaker import get_circuit_breaker

_log = logging.getLogger(__name__)

# HMG 사내 SSL 프록시 우회 — edge_tts 내부 SSL 컨텍스트 교체
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE
_ec._SSL_CTX = _ssl_ctx

SPOOL_DIR = Path("/tmp/tts-spool")
EDGE_VOICE = "ko-KR-HyunsuMultilingualNeural"


def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)


async def _generate_edge(text: str) -> Path:
    out = Path(tempfile.mktemp(suffix=".mp3", prefix="vp_edge_"))
    comm = edge_tts.Communicate(text, EDGE_VOICE)
    await comm.save(str(out))
    return out


async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2,
                     edge_timeout: float = 10.0) -> None:
    edge_cb = get_circuit_breaker("edge_tts")

    async def _edge_call() -> Path:
        return await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)

    try:
        mp3 = await edge_cb.call(_edge_call, fallback=None)
        if mp3 is not None:
            _enqueue_spool(mp3, speed)
            save_last_message(text)
    except Exception as e:
        _log.warning("EdgeTTS 생성 실패: %s", type(e).__name__)


async def _generate_supertonic(
    text: str, voice: str, port: int, steps: int = 12, timeout: float = 20.0
) -> bytes:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"http://localhost:{port}/v1/tts",
            json={"text": text, "voice": voice, "lang": "ko",
                  "steps": steps, "response_format": "wav"},
            timeout=timeout,
        )
        r.raise_for_status()
        return r.content


def _dynamic_steps(text: str, base_steps: int) -> int:
    """텍스트 길이에 따라 diffusion steps 동적 조정 — 100자 미만이면 최소 8 steps."""
    return min(8, base_steps) if len(text) < 100 else base_steps


async def speak_agent(text: str, voice: str, port: int, speed: float, instruct: str = "",
                      steps: int = 12, supertonic_timeout: float = 20.0) -> None:
    if not text.strip():
        return
    actual_steps = _dynamic_steps(text, steps)
    st_cb = get_circuit_breaker("supertonic")

    async def _st_call() -> bytes:
        return await asyncio.wait_for(
            _generate_supertonic(text, voice, port, steps=actual_steps, timeout=supertonic_timeout),
            timeout=supertonic_timeout,
        )

    try:
        wav_bytes = await st_cb.call(_st_call, fallback=None)
        if wav_bytes is not None:
            tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
    except Exception as e:
        _log.warning("Supertonic 생성 실패: %s", type(e).__name__)
