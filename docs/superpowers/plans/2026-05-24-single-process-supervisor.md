# Single-Process Supervisor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TTS Server·Supertonic·TTS Player 세 컴포넌트를 단일 Python supervisor 프로세스로 묶어 launchd가 하나의 진입점만 관리하도록 한다.

**Architecture:** `tts_server/supervisor.py`가 uvicorn과 supertonic을 `subprocess.Popen`으로 fork하고, TTS Player 스풀 폴링 로직을 `asyncio` Task로 흡수한다. `server.sh`는 PID 파일 하나로 supervisor를 제어하도록 단순화한다.

**Tech Stack:** Python 3.11+, asyncio, subprocess, pathlib, signal. pytest (동기 래퍼에서 asyncio.run() 사용).

**Spec:** `docs/superpowers/specs/2026-05-24-single-process-supervisor-design.md`

---

## 파일 변경 요약

| 파일 | 동작 |
|---|---|
| `tts_server/supervisor.py` | 신규 — supervisor 진입점 |
| `tts_server/test_supervisor.py` | 신규 — supervisor 단위 테스트 |
| `server.sh` | 수정 — supervisor 기반으로 전환 |
| `tts_server/start.sh` | 삭제 |
| `tts_server/stop.sh` | 삭제 |
| `tts_server/supertonic_start.sh` | 삭제 |
| `tts_server/supertonic_stop.sh` | 삭제 |
| `tts_server/tts_player.sh` | 삭제 |

---

## Task 1: `_do_cleanup` — 스풀 stale 파일 정리 함수

**Files:**
- Create: `tts_server/supervisor.py` (초안 — 이후 태스크에서 확장)
- Create: `tts_server/test_supervisor.py`

### 1-1. 실패 테스트 작성

`tts_server/test_supervisor.py`를 아래 내용으로 생성한다.

```python
# tts_server supervisor 단위 테스트
import asyncio
import os
import time
from pathlib import Path


# mlx 없는 환경에서도 import 가능하도록 사전 stub
import sys
sys.modules.setdefault("mlx_audio", type(sys)("mlx_audio"))
sys.modules.setdefault("mlx_audio.tts", type(sys)("mlx_audio.tts"))
sys.modules.setdefault("mlx_audio.tts.generate", type(sys)("mlx_audio.tts.generate"))
sys.modules.setdefault("mlx_audio.tts.utils", type(sys)("mlx_audio.tts.utils"))


class TestDoCleanup:
    def test_old_files_removed(self, tmp_path):
        """5분 초과 오디오 파일은 삭제된다."""
        from tts_server.supervisor import _do_cleanup

        old = tmp_path / "1000.wav"
        old.write_bytes(b"old")
        old_time = time.time() - 360  # 6분 전
        os.utime(str(old), (old_time, old_time))

        fresh = tmp_path / "9999999.wav"
        fresh.write_bytes(b"fresh")

        _do_cleanup(tmp_path)

        assert not old.exists(), "6분 전 파일은 삭제되어야 한다"
        assert fresh.exists(), "최신 파일은 유지되어야 한다"

    def test_max_files_enforced(self, tmp_path):
        """파일이 10개 초과면 오래된 것부터 제거한다."""
        from tts_server.supervisor import _do_cleanup

        for i in range(12):
            (tmp_path / f"{1000 + i}.wav").write_bytes(b"x")

        _do_cleanup(tmp_path)

        remaining = list(tmp_path.glob("*.wav"))
        assert len(remaining) == 10, f"10개만 남아야 하는데 {len(remaining)}개"

    def test_meta_files_removed_with_audio(self, tmp_path):
        """오래된 오디오 파일 삭제 시 대응 .meta 파일도 함께 삭제된다."""
        from tts_server.supervisor import _do_cleanup

        old_wav = tmp_path / "1000.wav"
        old_wav.write_bytes(b"old")
        old_meta = tmp_path / "1000.meta"
        old_meta.write_text("1.2")
        old_time = time.time() - 360
        os.utime(str(old_wav), (old_time, old_time))
        os.utime(str(old_meta), (old_time, old_time))

        _do_cleanup(tmp_path)

        assert not old_wav.exists()
        assert not old_meta.exists()
```

- [ ] **Step 1:** 위 내용으로 `tts_server/test_supervisor.py` 파일 생성

### 1-2. 테스트가 실패하는지 확인

- [ ] **Step 2:** 아래 명령 실행, `ImportError: cannot import name '_do_cleanup'` 류 오류 확인

```bash
cd /Users/hmc7102758/Develop/Workspaces/chorus
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestDoCleanup -v
```

예상 결과: **FAILED** (ImportError 또는 ModuleNotFoundError)

### 1-3. `supervisor.py` 초안 — `_do_cleanup` 구현

`tts_server/supervisor.py`를 아래 내용으로 생성한다.

```python
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
```

- [ ] **Step 3:** 위 내용으로 `tts_server/supervisor.py` 생성

### 1-4. 테스트 통과 확인

- [ ] **Step 4:** 아래 명령 실행, 모든 테스트 PASSED 확인

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestDoCleanup -v
```

예상 결과:
```
PASSED tts_server/test_supervisor.py::TestDoCleanup::test_old_files_removed
PASSED tts_server/test_supervisor.py::TestDoCleanup::test_max_files_enforced
PASSED tts_server/test_supervisor.py::TestDoCleanup::test_meta_files_removed_with_audio
```

### 1-5. 커밋

- [ ] **Step 5:**

```bash
git add tts_server/supervisor.py tts_server/test_supervisor.py
git commit -m "feat: supervisor _do_cleanup 구현 및 테스트 추가"
```

---

## Task 2: `player_loop` — asyncio 스풀 재생 Task

**Files:**
- Modify: `tts_server/supervisor.py` — `player_loop` 추가
- Modify: `tts_server/test_supervisor.py` — `TestPlayerLoop` 추가

### 2-1. 실패 테스트 작성

`tts_server/test_supervisor.py` 하단에 추가한다.

```python
class TestPlayerLoop:
    def test_plays_wav_with_default_speed(self, tmp_path):
        """wav 파일이 있고 meta 없으면 speed=1.2로 afplay 호출한다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "1000.wav"
        audio.write_bytes(b"audio")

        played = []
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            played.append(args)
            shutdown.set()  # 1회 재생 후 종료
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert len(played) == 1
        assert played[0] == ("afplay", "-r", "1.2", str(audio))

    def test_reads_speed_from_meta(self, tmp_path):
        """.meta 파일이 있으면 그 값을 speed로 사용한다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "2000.wav"
        audio.write_bytes(b"audio")
        (tmp_path / "2000.meta").write_text("1.5")

        played = []
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            played.append(args)
            shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert played[0][2] == "1.5"

    def test_deletes_audio_after_play(self, tmp_path):
        """재생 완료 후 오디오 파일이 삭제된다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "3000.mp3"
        audio.write_bytes(b"audio")

        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert not audio.exists(), "재생 후 파일이 삭제되어야 한다"

    def test_epoch_ascending_order(self, tmp_path):
        """여러 파일이 있으면 epoch_ms 오름차순(가장 오래된 것) 먼저 재생한다."""
        from unittest.mock import AsyncMock, patch

        (tmp_path / "9000.wav").write_bytes(b"later")
        (tmp_path / "1000.wav").write_bytes(b"earlier")

        played = []
        call_count = 0
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            nonlocal call_count
            played.append(Path(args[-1]).name)
            call_count += 1
            if call_count >= 2:
                shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert played[0] == "1000.wav", "오래된 파일이 먼저 재생되어야 한다"
```

- [ ] **Step 1:** 위 내용을 `tts_server/test_supervisor.py` 하단에 추가

### 2-2. 테스트 실패 확인

- [ ] **Step 2:**

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestPlayerLoop -v
```

예상 결과: **FAILED** (ImportError: `player_loop` 없음)

### 2-3. `player_loop` 구현

`tts_server/supervisor.py`에 `_do_cleanup` 다음에 추가한다.

```python
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
            try:
                if "audio" in dir() and Path(audio).exists():
                    Path(audio).unlink(missing_ok=True)
            except Exception:
                pass
```

`supervisor.py`의 전역 영역(상수 정의 직후)에 shutdown 이벤트 선언도 추가한다.

```python
_shutdown_event = asyncio.Event()
```

- [ ] **Step 3:** `supervisor.py`에 `_shutdown_event` 전역 변수와 `player_loop` 함수 추가

### 2-4. 테스트 통과 확인

- [ ] **Step 4:**

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestPlayerLoop -v
```

예상 결과: 4개 모두 PASSED

### 2-5. 커밋

- [ ] **Step 5:**

```bash
git add tts_server/supervisor.py tts_server/test_supervisor.py
git commit -m "feat: supervisor player_loop asyncio Task 구현 및 테스트 추가"
```

---

## Task 3: `cleanup_loop` + `monitor_children` + 자식 프로세스 기동

**Files:**
- Modify: `tts_server/supervisor.py` — 나머지 함수 추가
- Modify: `tts_server/test_supervisor.py` — `TestMonitorChildren` 추가

### 3-1. 실패 테스트 작성

`tts_server/test_supervisor.py` 하단에 추가한다.

```python
class TestMonitorChildren:
    def test_sets_shutdown_on_child_exit(self):
        """자식 프로세스가 종료되면 shutdown 이벤트를 set한다."""
        from unittest.mock import MagicMock
        from tts_server.supervisor import monitor_children

        proc = MagicMock()
        proc.pid = 9999
        proc.poll.return_value = 1  # 비정상 종료

        shutdown = asyncio.Event()

        async def run():
            await monitor_children([proc], shutdown=shutdown)

        asyncio.run(run())
        assert shutdown.is_set(), "자식 종료 시 shutdown 이벤트가 set되어야 한다"

    def test_does_not_shutdown_while_children_running(self):
        """자식이 정상 실행 중이면 shutdown을 set하지 않는다."""
        from unittest.mock import MagicMock
        from tts_server.supervisor import monitor_children

        proc = MagicMock()
        proc.pid = 9998
        proc.poll.return_value = None  # 실행 중

        shutdown = asyncio.Event()

        async def run():
            # 3회 poll 후 외부에서 shutdown 트리거 (루프 탈출)
            call_count = 0
            original_poll = proc.poll

            def patched_poll():
                nonlocal call_count
                call_count += 1
                if call_count >= 3:
                    shutdown.set()
                return None

            proc.poll = patched_poll
            await monitor_children([proc], shutdown=shutdown)

        asyncio.run(run())
        # shutdown은 patched_poll에서 set했지만 monitor_children이 먼저 set하지 않아야 함
        # (검증: poll이 None 반환 중에는 monitor가 set하지 않음)
        assert proc.poll.call_count >= 3
```

- [ ] **Step 1:** 위 내용을 `tts_server/test_supervisor.py` 하단에 추가

### 3-2. 테스트 실패 확인

- [ ] **Step 2:**

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestMonitorChildren -v
```

예상 결과: **FAILED** (ImportError: `monitor_children` 없음)

### 3-3. 나머지 함수 구현

`tts_server/supervisor.py`에 `player_loop` 다음에 추가한다.

```python
async def cleanup_loop(
    spool: Path = SPOOL_DIR,
    shutdown: "asyncio.Event | None" = None,
    interval: float = 1800.0,
) -> None:
    """시작 시 1회 + 30분 주기로 stale 파일 정리."""
    if shutdown is None:
        shutdown = _shutdown_event
    _do_cleanup(spool)
    while not shutdown.is_set():
        try:
            await asyncio.wait_for(shutdown.wait(), timeout=interval)
        except asyncio.TimeoutError:
            _do_cleanup(spool)


async def monitor_children(
    procs: "list[subprocess.Popen]",
    shutdown: "asyncio.Event | None" = None,
) -> None:
    """자식 프로세스를 1초 주기로 감시 — 비정상 종료 시 shutdown 이벤트 set."""
    if shutdown is None:
        shutdown = _shutdown_event
    while not shutdown.is_set():
        for proc in procs:
            rc = proc.poll()
            if rc is not None:
                log.error(f"[Monitor] 자식 PID {proc.pid} 비정상 종료 (returncode={rc})")
                shutdown.set()
                return
        await asyncio.sleep(1)


def _start_uvicorn() -> subprocess.Popen:
    """uvicorn 자식 프로세스를 기동하고 Popen 객체를 반환한다."""
    log_fd = open(LOG_FILE, "a")
    return subprocess.Popen(
        [str(VENV_BIN / "uvicorn"), "tts_server.server:app",
         "--host", "127.0.0.1", "--port", "7777"],
        env={**os.environ, "HF_HUB_OFFLINE": "1"},
        stdout=log_fd,
        stderr=log_fd,
    )


def _start_supertonic() -> subprocess.Popen:
    """supertonic 자식 프로세스를 기동하고 Popen 객체를 반환한다."""
    supertonic_log = open("/tmp/supertonic.log", "a")
    return subprocess.Popen(
        [str(VENV_BIN / "supertonic"), "serve",
         "--host", "127.0.0.1", "--port", "7788"],
        env={**os.environ, "HF_HUB_OFFLINE": "0"},
        stdout=supertonic_log,
        stderr=supertonic_log,
    )


async def _graceful_shutdown(procs: list[subprocess.Popen]) -> None:
    """자식 프로세스를 역순 SIGTERM → 5초 후 SIGKILL로 종료한다."""
    log.info("[Supervisor] 종료 시작...")
    loop = asyncio.get_running_loop()
    deadline = loop.time() + 5.0
    for proc in reversed(procs):   # supertonic → uvicorn 순서
        proc.terminate()
    for proc in procs:
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
```

- [ ] **Step 3:** 위 함수들을 `tts_server/supervisor.py`에 추가

### 3-4. 테스트 통과 확인

- [ ] **Step 4:**

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py::TestMonitorChildren -v
```

예상 결과: 2개 모두 PASSED

### 3-5. 전체 테스트 확인

- [ ] **Step 5:**

```bash
./tts-venv/bin/pytest tts_server/test_supervisor.py -v
```

예상 결과: 9개 모두 PASSED

### 3-6. 커밋

- [ ] **Step 6:**

```bash
git add tts_server/supervisor.py tts_server/test_supervisor.py
git commit -m "feat: supervisor cleanup_loop, monitor_children, 자식 기동·종료 함수 구현"
```

---

## Task 4: `main()` — supervisor 진입점 완성

**Files:**
- Modify: `tts_server/supervisor.py` — `main()` + `if __name__ == "__main__"` 추가

### 4-1. `main()` 구현

`tts_server/supervisor.py` 하단에 추가한다.

```python
async def main() -> None:
    PID_FILE.write_text(str(os.getpid()))
    log.info(f"[Supervisor] 시작 (PID {os.getpid()})")

    uvicorn_proc = _start_uvicorn()
    log.info(f"[Supervisor] uvicorn 기동 (PID {uvicorn_proc.pid})")

    supertonic_proc = _start_supertonic()
    log.info(f"[Supervisor] supertonic 기동 (PID {supertonic_proc.pid})")

    procs = [uvicorn_proc, supertonic_proc]
    loop = asyncio.get_running_loop()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown_event.set)

    try:
        await asyncio.gather(
            player_loop(),
            cleanup_loop(),
            monitor_children(procs),
        )
    finally:
        await _graceful_shutdown(procs)
        PID_FILE.unlink(missing_ok=True)
        # 자식 중 하나라도 비정상 종료면 exit(1) → launchd 재시작 트리거
        if any(p.returncode not in (None, 0) for p in procs):
            sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 1:** 위 내용을 `tts_server/supervisor.py` 하단에 추가

### 4-2. 수동 smoke test

supertonic이 없는 환경에서 uvicorn만 기동되는지 확인한다.

- [ ] **Step 2:** 터미널에서 아래 명령 실행 (Ctrl+C로 종료)

```bash
cd /Users/hmc7102758/Develop/Workspaces/chorus
./tts-venv/bin/python tts_server/supervisor.py
```

예상 로그 (supertonic 미설치 시 에러는 정상):
```
HH:MM:SS [supervisor] [Supervisor] 시작 (PID XXXXXX)
HH:MM:SS [supervisor] [Supervisor] uvicorn 기동 (PID XXXXXX)
HH:MM:SS [supervisor] [Supervisor] supertonic 기동 (PID XXXXXX)
```

- [ ] **Step 3:** Ctrl+C 후 `.tts_server.pid` 파일이 삭제되었는지 확인

```bash
ls -la .tts_server.pid 2>/dev/null && echo "남아있음" || echo "정상 삭제됨"
```

예상: `정상 삭제됨`

### 4-3. 커밋

- [ ] **Step 4:**

```bash
git add tts_server/supervisor.py
git commit -m "feat: supervisor main() 진입점 및 signal 핸들러 구현"
```

---

## Task 5: `server.sh` — supervisor 기반으로 전환

**Files:**
- Modify: `server.sh`

### 5-1. server.sh 수정

`server.sh`의 아래 함수들을 삭제하고 대체 함수를 추가한다.

**삭제할 함수 (내용 전체 제거):**
- `_supertonic_running()` (48~50행)
- `_player_running()` (53~55행)
- `_start_player()` (57~61행)
- `_stop_player()` (63~68행)

**대체 추가 (`_tts_running` 바로 뒤에 삽입):**

```bash
_supervisor_running() {
  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}
```

**`do_start()` 전체 교체:**

```bash
do_start() {
  _check_deps

  if _is_launchd_managed; then
    echo "launchd 서비스가 supervisor를 관리 중입니다."
    echo "  일시 중지: launchctl stop  $LAUNCHD_LABEL"
    echo "  재시작:    launchctl start $LAUNCHD_LABEL"
    echo "  완전 제거: $(basename "$0") uninstall"
    return 0
  fi

  if _supervisor_running; then
    local pid
    pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
    echo "이미 실행 중 (supervisor PID: $pid)"
    return 0
  fi

  echo "Supervisor 시작 중..."
  nohup "$SCRIPT_DIR/tts-venv/bin/python" \
      "$SCRIPT_DIR/tts_server/supervisor.py" \
      >> "$LOG_FILE" 2>&1 &
  disown $!

  local i=0
  while (( i < 10 )); do
    if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
      echo "✓ TTS 서버 기동 완료 (HTTP 200)"
      return 0
    fi
    sleep 1
    i=$(( i + 1 ))
  done
  echo "✓ Supervisor 기동됨 — 모델 로딩 중, 잠시 후 응답 예정"
}
```

**`do_stop()` 전체 교체:**

```bash
do_stop() {
  if _is_launchd_managed; then
    echo "launchd 관리 서버 종료 중 (launchctl stop)..."
    launchctl stop "$LAUNCHD_LABEL"
    local i=0
    while (( i < 8 )); do
      _supervisor_running || break
      sleep 1
      i=$(( i + 1 ))
    done
    return 0
  fi

  if ! _supervisor_running; then
    echo "Supervisor가 실행 중이지 않습니다."
    return 0
  fi

  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
  echo "Supervisor 종료 중 (PID $pid)..."
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while (( i < 8 )); do
    _supervisor_running || break
    sleep 1
    i=$(( i + 1 ))
  done
  rm -f "$SCRIPT_DIR/.tts_server.pid"
  echo "종료 완료"
}
```

**`do_status()` 수정 — TTS Server 항목과 TTS Player 항목 통합:**

기존 TTS 서버 항목은 유지하되 TTS Player 블록(205~213행)을 삭제하고, Supertonic 블록은 포트 확인으로 유지한다.

TTS 서버 상태 블록을:
```bash
  if _tts_running; then
```
를:
```bash
  if _supervisor_running; then
    local pid
    pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
    echo "  Supervisor: ✓ 실행 중 (PID: $pid)"
  else
    echo "  Supervisor: ✗ 중지됨"
  fi

  if _tts_running; then
```
으로 교체한다.

**`do_install()` 수정 — launchd ProgramArguments:**

`do_install` 함수에서 `LAUNCHD_PLIST` 생성 heredoc 내 `<key>ProgramArguments</key>` 블록을 아래로 교체한다.

```xml
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/tts-venv/bin/python</string>
    <string>${SCRIPT_DIR}/tts_server/supervisor.py</string>
  </array>
```

`do_install` 함수에서 `_start_player`, `_supertonic_running` 호출 라인을 모두 제거한다.
Supertonic은 supervisor가 내부에서 기동하므로 별도 `bash supertonic_start.sh` 호출이 불필요하다.

- [ ] **Step 1:** 위 변경 사항을 `server.sh`에 적용

### 5-2. 문법 확인

- [ ] **Step 2:**

```bash
bash -n server.sh && echo "문법 오류 없음"
```

예상: `문법 오류 없음`

### 5-3. status 명령 확인 (서버 미실행 상태)

- [ ] **Step 3:**

```bash
./server.sh status
```

예상: `Supervisor: ✗ 중지됨` 출력

### 5-4. 커밋

- [ ] **Step 4:**

```bash
git add server.sh
git commit -m "feat: server.sh supervisor 기반 전환 — player/supertonic 직접 관리 제거"
```

---

## Task 6: 마이그레이션 실행 및 구 스크립트 삭제

**Files:**
- Delete: `tts_server/start.sh`, `tts_server/stop.sh`, `tts_server/supertonic_start.sh`, `tts_server/supertonic_stop.sh`, `tts_server/tts_player.sh`

### 6-1. 기존 설치 제거

- [ ] **Step 1:** 기존 launchd 등록 및 프로세스 전체 정리

```bash
./server.sh uninstall
```

예상: Stop hook 제거, SubagentStop hook 제거, 프로세스 종료, LaunchAgent 제거 메시지

### 6-2. 새 supervisor 기반 설치

- [ ] **Step 2:**

```bash
npm run build && ./server.sh install
```

예상:
```
Stop hook 등록 중...
SubagentStop hook 등록 중...
TTS LaunchAgent 등록 중...
  ✓ LaunchAgent 등록 완료
✓ voice-persona 설치 완료
```

### 6-3. 동작 확인

- [ ] **Step 3:**

```bash
./server.sh status
```

예상:
```
● voice-persona 상태
  빌드:      ✓ dist/index.js (...)
  Supervisor: ✓ 실행 중 (PID: XXXXX)
  TTS 서버:  ✓ 실행 중 (PID: ..., 포트 7777)
  HTTP:      ✓ /health 응답 정상
  Supertonic: ✓ 실행 중 (PID: ..., 포트 7788)
  Stop hook: ✓ 등록됨
  launchd:   ✓ 등록됨 (자동 재시작 활성화)
```

### 6-4. 구 스크립트 삭제

- [ ] **Step 4:**

```bash
git rm tts_server/start.sh \
       tts_server/stop.sh \
       tts_server/supertonic_start.sh \
       tts_server/supertonic_stop.sh \
       tts_server/tts_player.sh
```

### 6-5. 전체 테스트 실행

- [ ] **Step 5:**

```bash
./tts-venv/bin/pytest tts_server/ -v
```

예상: `test_server.py`와 `test_supervisor.py` 모두 PASSED

### 6-6. 최종 커밋

- [ ] **Step 6:**

```bash
git commit -m "chore: supervisor 마이그레이션 완료 — 구 스크립트 삭제"
```

---

## 검증 체크리스트

마이그레이션 완료 후 아래를 확인한다.

- [ ] `./server.sh status` — Supervisor·TTS 서버·Supertonic 모두 ✓
- [ ] `./server.sh stop && ./server.sh start` — 재시작 정상 동작
- [ ] Claude Code 응답 완료 시 TTS 음성 재생 확인 (Stop hook)
- [ ] 서브에이전트 발화 확인 (SubagentStop hook)
- [ ] 재부팅 후 launchd 자동 시작 확인 (`launchctl list com.voice-persona.tts-server`)
