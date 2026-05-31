# hook_voice/player.py
# EdgeTTS → spool enqueue, speak_hook / speak_agent + HTTP / subprocess 폴백
import asyncio
import logging
import os
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
TTS_SERVER_URL = "http://localhost:7777"
MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
MLX_SPEAKERS = {"Sohee", "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna"}


def _venv_python() -> Path:
    env = os.environ.get("VOICE_PERSONA_VENV_PYTHON")
    return Path(env) if env else Path(__file__).parent.parent / ".venv" / "bin" / "python3"


def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))  # 1.0→100, 1.2→120, 1.25→125
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)
    # .meta 파일 없음 — speed는 파일명에 인코딩됨


async def _generate_edge(text: str) -> Path:
    out = Path(tempfile.mktemp(suffix=".mp3", prefix="vp_edge_"))
    comm = edge_tts.Communicate(text, EDGE_VOICE)
    await comm.save(str(out))
    return out


async def _is_tts_server_alive() -> bool:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{TTS_SERVER_URL}/health", timeout=0.5)
            return r.is_success
    except Exception:
        return False


async def _speak_http(text: str, voice: str, speed: float, instruct: str = "") -> bool:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{TTS_SERVER_URL}/speak",
            json={"text": text, "voice": voice, "lang_code": "korean", "speed": speed, "instruct": instruct},
            timeout=10.0,
        )
        if r.status_code == 429:
            _log.warning("TTS HTTP server busy (429), subprocess fallback")
            return False
        r.raise_for_status()
        return True


def _speed_to_wpm(speed: float) -> int:
    return max(80, min(360, round(175 * speed)))


async def _speak_with_mlx_cli(text: str, voice: str, speed: float) -> None:
    py = _venv_python()
    proc = await asyncio.create_subprocess_exec(
        str(py), "-m", "mlx_audio.tts.generate",
        "--model", MLX_MODEL,
        "--text", text, "--voice", voice,
        "--lang_code", "korean", "--speed", str(speed),
        "--output_path", "/tmp", "--play",
        env={**os.environ, "HF_HUB_OFFLINE": "1"},
    )
    await proc.wait()


async def _speak_with_macos_say(text: str, voice: str, speed: float) -> None:
    args = ["say", "-r", str(_speed_to_wpm(speed))]
    if voice:
        args.extend(["-v", voice])
    args.append(text)
    proc = await asyncio.create_subprocess_exec(*args)
    await proc.wait()


async def _speak_subprocess(text: str, voice: str, speed: float) -> None:
    py = _venv_python()
    if voice in MLX_SPEAKERS and py.exists():
        await _speak_with_mlx_cli(text, voice, speed)
    else:
        await _speak_with_macos_say(text, voice, speed)


async def _speak_without_edge(text: str, voice: str, speed: float, instruct: str = "") -> None:
    if await _is_tts_server_alive():
        try:
            if await _speak_http(text, voice, speed, instruct):
                save_last_message(text)
                return
        except Exception as e:
            _log.warning("TTS HTTP failed, subprocess fallback: %s", type(e).__name__)
    else:
        _log.info("TTS server unavailable, subprocess fallback")
    await _speak_subprocess(text, voice, speed)
    save_last_message(text)


async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2,
                     edge_timeout: float = 10.0) -> None:
    skip_edge = os.environ.get("VOICE_PERSONA_OFFLINE") == "1"
    if not skip_edge and _venv_python().exists():
        edge_cb = get_circuit_breaker("edge_tts")

        async def _edge_call() -> Path:
            return await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)

        try:
            mp3 = await edge_cb.call(_edge_call, fallback=None)
            if mp3 is not None:
                _enqueue_spool(mp3, speed)
                save_last_message(text)
                return
        except Exception as e:
            _log.warning("Edge generation failed, local fallback: %s", type(e).__name__)
    await _speak_without_edge(text, voice, speed)


async def _is_supertonic_alive(port: int) -> bool:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"http://localhost:{port}/v1/health", timeout=0.5)
            return r.is_success
    except Exception:
        return False


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
    """텍스트 길이에 따라 diffusion steps 동적 조정 — 짧은 발화일수록 빠르게."""
    n = len(text)
    if n < 30:  return min(4, base_steps)
    if n < 60:  return min(6, base_steps)
    if n < 100: return min(8, base_steps)
    return base_steps


async def speak_agent(text: str, voice: str, port: int, speed: float, instruct: str = "",
                      steps: int = 12, supertonic_timeout: float = 20.0) -> None:
    if not text.strip():
        return
    actual_steps = _dynamic_steps(text, steps)
    if await _is_supertonic_alive(port):
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
                return
        except Exception as e:
            _log.warning("Supertonic generation failed, generic fallback: %s", type(e).__name__)
    else:
        _log.info("Supertonic unavailable, generic fallback")
    await _speak_without_edge(text, voice, speed, instruct)
