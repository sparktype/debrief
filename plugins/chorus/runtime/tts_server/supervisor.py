# Python supervisor — uvicorn·supertonic·TTS Player를 단일 프로세스로 관리
import asyncio
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

from hook_voice.config import load_config

PROJECT_DIR = Path(__file__).parent.parent
VENV_BIN = PROJECT_DIR / ".venv" / "bin"
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
            except Exception:
                pass

        remaining = sorted(list(spool.glob("*.wav")) + list(spool.glob("*.mp3")))
        excess = len(remaining) - MAX_FILES
        if excess > 0:
            for f in remaining[:excess]:
                f.unlink(missing_ok=True)
    except Exception as e:
        log.warning(f"[Cleanup] 오류: {e}")


async def player_loop(
    spool: Path = SPOOL_DIR,
    shutdown: "asyncio.Event | None" = None,
) -> None:
    """스풀 디렉토리를 폴링하며 오디오 파일을 순차 재생한다."""
    if shutdown is None:
        shutdown = asyncio.Event()
    spool.mkdir(exist_ok=True)
    idle = 0
    while not shutdown.is_set():
        audio: "Path | None" = None
        try:
            files = sorted(list(spool.glob("*.wav")) + list(spool.glob("*.mp3")))
            if files:
                audio = files[0]
                stem_parts = audio.stem.rsplit("_", 1)
                if len(stem_parts) == 2 and stem_parts[-1].isdigit():
                    speed = str(int(stem_parts[-1]) / 100)  # "120" → "1.2"
                else:
                    speed = "1.0"
                proc = await asyncio.create_subprocess_exec(
                    "afplay", "-r", speed, str(audio)
                )
                pid_file = spool / ".player.pid"
                try:
                    pid_file.write_text(str(proc.pid))
                except Exception:
                    pass
                # shutdown 이벤트와 재생 완료를 동시에 대기
                play_task = asyncio.ensure_future(proc.wait())
                done, pending = await asyncio.wait(
                    [play_task, asyncio.ensure_future(shutdown.wait())],
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if shutdown.is_set() and proc.returncode is None:
                    # shutdown이 set돼도 현재 재생 중인 파일은 끝까지 재생
                    try:
                        await asyncio.wait_for(proc.wait(), timeout=30.0)
                    except asyncio.TimeoutError:
                        proc.terminate()
                        try:
                            await asyncio.wait_for(proc.wait(), timeout=2.0)
                        except asyncio.TimeoutError:
                            proc.kill()
                            await proc.wait()
                for t in pending:
                    t.cancel()
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)
                try:
                    pid_file.unlink(missing_ok=True)
                except Exception:
                    pass
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
            try:
                (spool / ".player.pid").unlink(missing_ok=True)
            except Exception:
                pass
            idle = 0


async def cleanup_loop(
    spool: Path = SPOOL_DIR,
    shutdown: "asyncio.Event | None" = None,
    interval: float = 1800.0,
) -> None:
    """시작 시 1회 + 30분 주기로 stale 파일 정리."""
    if shutdown is None:
        shutdown = asyncio.Event()
    _do_cleanup(spool)
    while not shutdown.is_set():
        try:
            await asyncio.wait_for(shutdown.wait(), timeout=interval)
        except asyncio.TimeoutError:
            _do_cleanup(spool)


async def monitor_children(
    procs: "list[subprocess.Popen]",
    shutdown: "asyncio.Event | None" = None,
    sleep_sec: float = 1.0,
    restartable_idx: "int | None" = None,
    restart_fn: "Callable[[], subprocess.Popen] | None" = None,
) -> None:
    """자식 프로세스를 1초 주기로 감시.

    restartable_idx 인덱스의 프로세스(supertonic)가 crash되면 restart_fn으로 재시작.
    그 외 프로세스(uvicorn) crash 시 shutdown 이벤트를 set한다.
    """
    if shutdown is None:
        shutdown = asyncio.Event()
    while not shutdown.is_set():
        for i, proc in enumerate(procs):
            rc = proc.poll()
            if rc is not None:
                if i == restartable_idx and restart_fn is not None:
                    log.warning(f"[Monitor] supertonic PID {proc.pid} crash (rc={rc}) — 재시작")
                    procs[i] = restart_fn()
                    log.info(f"[Monitor] supertonic 재시작 (PID {procs[i].pid})")
                else:
                    log.error(f"[Monitor] 자식 PID {proc.pid} 비정상 종료 (returncode={rc})")
                    shutdown.set()
                    return
        await asyncio.sleep(sleep_sec)


def _start_uvicorn() -> subprocess.Popen:
    """uvicorn 자식 프로세스를 기동하고 Popen 객체를 반환한다."""
    with open(LOG_FILE, "a") as log_fd:
        return subprocess.Popen(
            [str(VENV_BIN / "uvicorn"), "tts_server.server:app",
             "--host", "127.0.0.1", "--port", "7777"],
            env={**os.environ, "HF_HUB_OFFLINE": "1"},
            stdout=log_fd,
            stderr=log_fd,
            cwd=str(PROJECT_DIR),
        )


async def _graceful_shutdown(procs: "list[subprocess.Popen]") -> None:
    """자식 프로세스를 역순 SIGTERM → 5초 후 SIGKILL로 종료한다."""
    log.info("[Supervisor] 종료 시작...")
    loop = asyncio.get_running_loop()
    deadline = loop.time() + 5.0
    for proc in reversed(procs):   # supertonic → uvicorn 순서
        if proc.poll() is None:    # 이미 종료된 프로세스는 건너뜀
            proc.terminate()
    for proc in procs:
        if proc.poll() is not None:
            continue
        remaining = max(0.1, deadline - loop.time())
        try:
            await asyncio.wait_for(
                loop.run_in_executor(None, proc.wait),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            log.warning(f"[Supervisor] PID {proc.pid} 응답 없음 — SIGKILL")
            proc.kill()
    log.info("[Supervisor] 종료 완료")


async def main() -> None:
    shutdown = asyncio.Event()
    try:
        PID_FILE.write_text(str(os.getpid()))
    except OSError as e:
        log.warning("[Supervisor] PID 파일 쓰기 실패 (무시): %s", e)
    log.info(f"[Supervisor] 시작 (PID {os.getpid()})")

    procs: list[subprocess.Popen] = []
    loop = asyncio.get_running_loop()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, shutdown.set)

    try:
        uvicorn_proc = _start_uvicorn()
        procs.append(uvicorn_proc)
        log.info(f"[Supervisor] uvicorn 기동 (PID {uvicorn_proc.pid})")

        await asyncio.gather(
            player_loop(shutdown=shutdown),
            cleanup_loop(shutdown=shutdown),
            monitor_children(procs, shutdown=shutdown),
        )
    finally:
        await _graceful_shutdown(procs)
        PID_FILE.unlink(missing_ok=True)
        # 자식 중 하나라도 비정상 종료면 exit(1) → launchd 재시작 트리거
        if any(p.returncode not in (None, 0) for p in procs):
            sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
