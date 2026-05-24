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
