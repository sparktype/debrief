# hook_voice/player.py
# EdgeTTS → spool enqueue, speak_hook / speak_agent + HTTP / subprocess 폴백
import asyncio
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
    dest = SPOOL_DIR / f"{uid}{audio_file.suffix}"
    audio_file.rename(dest)
    (SPOOL_DIR / f"{uid}.meta").write_text(str(speed))


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


async def _speak_http(text: str, voice: str, speed: float) -> None:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{TTS_SERVER_URL}/speak",
            json={"text": text, "voice": voice, "lang_code": "korean", "speed": speed, "instruct": ""},
            timeout=10.0,
        )
        if r.status_code == 429:
            return
        r.raise_for_status()


async def _speak_subprocess(text: str, voice: str, speed: float) -> None:
    py = _venv_python()
    if voice in MLX_SPEAKERS and py.exists():
        proc = await asyncio.create_subprocess_exec(
            str(py), "-m", "mlx_audio.tts.generate",
            "--model", MLX_MODEL,
            "--text", text, "--voice", voice,
            "--lang_code", "korean", "--speed", str(speed),
            "--output_path", "/tmp", "--play",
            env={**os.environ, "HF_HUB_OFFLINE": "1"},
        )
        await proc.wait()
    else:
        proc = await asyncio.create_subprocess_exec("say", text)
        await proc.wait()


async def _speak_without_edge(text: str, voice: str, speed: float) -> None:
    if await _is_tts_server_alive():
        try:
            await _speak_http(text, voice, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_subprocess(text, voice, speed)
    save_last_message(text)


async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2) -> None:
    skip_edge = os.environ.get("VOICE_PERSONA_OFFLINE") == "1"
    if not skip_edge and _venv_python().exists():
        try:
            mp3 = await asyncio.wait_for(_generate_edge(text), timeout=10.0)
            _enqueue_spool(mp3, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed)


async def _is_supertonic_alive(port: int) -> bool:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"http://localhost:{port}/v1/health", timeout=0.5)
            return r.is_success
    except Exception:
        return False


async def _generate_supertonic(text: str, voice: str, port: int) -> bytes:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"http://localhost:{port}/v1/audio/speech",
            json={"model": "supertonic-3", "input": text, "voice": voice,
                  "response_format": "wav", "lang": "ko"},
            timeout=20.0,
        )
        r.raise_for_status()
        return r.content


async def speak_agent(text: str, voice: str, port: int, speed: float) -> None:
    if not text.strip():
        return
    if await _is_supertonic_alive(port):
        try:
            wav_bytes = await asyncio.wait_for(_generate_supertonic(text, voice, port), timeout=20.0)
            tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed)
