# Python supervisor — uvicorn·supertonic·TTS Player를 단일 프로세스로 관리
import asyncio
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

PROJECT_DIR = Path(__file__).parent.parent
VENV_BIN = PROJECT_DIR / "tts-venv" / "bin"
PID_FILE = PROJECT_DIR / ".tts_server.pid"
LOG_FILE = PROJECT_DIR / ".tts_server.log"
SPOOL_DIR = Path("/tmp/tts-spool")

MAX_AGE_SECS = 300   # 5분
MAX_FILES = 10

_shutdown_event = asyncio.Event()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("supervisor")


def _do_cleanup(spool: Path = SPOOL_DIR) -> None:
    """stale 오디오 파일 정리 — 5분 초과 삭제, 10개 초과 시 오래된 순 제거."""
    try:
        now = time.time()
        all_files = sorted(list(spool.glob("*.wav")) + list(spool.glob("*.mp3")))
        for f in all_files:
            try:
                if now - f.stat().st_mtime > MAX_AGE_SECS:
                    f.unlink(missing_ok=True)
                    f.with_suffix(".meta").unlink(missing_ok=True)
            except Exception:
                pass

        remaining = sorted(list(spool.glob("*.wav")) + list(spool.glob("*.mp3")))
        excess = len(remaining) - MAX_FILES
        if excess > 0:
            for f in remaining[:excess]:
                f.unlink(missing_ok=True)
                f.with_suffix(".meta").unlink(missing_ok=True)
    except Exception as e:
        log.warning(f"[Cleanup] 오류: {e}")


async def player_loop(
    spool: Path = SPOOL_DIR,
    shutdown: "asyncio.Event | None" = None,
) -> None:
    """스풀 디렉토리를 폴링하며 오디오 파일을 순차 재생한다."""
    if shutdown is None:
        shutdown = _shutdown_event
    spool.mkdir(exist_ok=True)
    idle = 0
    while not shutdown.is_set():
        audio: "Path | None" = None
        try:
            files = sorted(list(spool.glob("*.wav")) + list(spool.glob("*.mp3")))
            if files:
                audio = files[0]
                meta = audio.with_suffix(".meta")
                speed = meta.read_text().strip() if meta.exists() else "1.2"
                meta.unlink(missing_ok=True)
                proc = await asyncio.create_subprocess_exec(
                    "afplay", "-r", speed, str(audio)
                )
                await proc.wait()
                audio.unlink(missing_ok=True)
                idle = 0
            else:
                idle += 1
                delay = min(0.3 * (1.5 ** idle), 2.0)
                await asyncio.sleep(delay)
        except Exception as e:
            log.error(f"[Player] 재생 오류: {e}")
            if audio is not None and audio.exists():
                audio.unlink(missing_ok=True)
            idle = 0
