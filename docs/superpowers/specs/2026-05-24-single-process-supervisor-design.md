# 설계 문서: Python supervisor 단일 프로세스 통합

**날짜:** 2026-05-24  
**상태:** 승인됨  
**작성자:** 박상선 책임매니저 (with Claude Code)

---

## 배경 및 문제

현재 summary-voice-mcp는 4개의 독립 프로세스로 구성되어 있다.

| 프로세스 | 실행 방식 | 관리 주체 |
|---|---|---|
| TTS Server (port 7777) | `nohup uvicorn` | launchd LaunchAgent |
| Supertonic Server (port 7788) | `nohup supertonic serve` | server.sh 직접 |
| TTS Player Daemon | `nohup bash tts_player.sh` | server.sh 직접 |
| MCP Server (Node.js) | Claude Code 직접 실행 | Claude Code |

**문제점:**
- launchd는 TTS Server만 감시하고, Supertonic·Player는 별도 관리 — 각자 죽어도 아무도 감지하지 않음
- `server.sh stop`이 TTS Player와 Supertonic을 별도로 종료해야 해서 로직이 분산됨
- `server.sh status`가 `lsof`, `pgrep`, `cat PID_FILE` 등 여러 수단을 혼용
- TTS Player 크래시 시 좀비 상태 가능

---

## 목표

- 세 Python 컴포넌트(TTS Server, Supertonic, TTS Player)를 **단일 Python supervisor** 아래로 묶음
- launchd는 supervisor 프로세스 하나만 관리
- `server.sh` 인터페이스는 동일하게 유지 (사용자 체감 변화 없음)

---

## 접근법: 얇은 Python supervisor (Approach A)

### 프로세스 구조

```
launchd
  └── supervisor.py (PID A)  ← 단일 진입점
        ├── subprocess.Popen: uvicorn (PID B)    port 7777
        ├── subprocess.Popen: supertonic (PID C) port 7788
        └── asyncio.Task: PlayerLoop             /tmp/tts-spool/ 폴링
```

**선택 이유:**
- 기존 `server.py` 코드 무변경 (MLX Metal GPU 단일 워커 스레드 제약 유지)
- uvicorn을 subprocess로 실행하므로 프로그래매틱 API의 복잡성 없음
- 구현 범위가 명확하고 가장 적은 코드 변경으로 운영 혼선 해소

---

## 상세 설계

### 1. 신규 파일: `tts_server/supervisor.py`

**기동 순서:**

```python
async def main():
    # 1. PID 파일 기록
    Path(PROJECT_DIR / ".tts_server.pid").write_text(str(os.getpid()))

    # 2. uvicorn 기동
    uvicorn_proc = subprocess.Popen(
        [VENV_BIN / "uvicorn", "tts_server.server:app",
         "--host", "127.0.0.1", "--port", "7777"],
        env={**os.environ, "HF_HUB_OFFLINE": "1"},
        stdout=log_fd, stderr=log_fd,
    )

    # 3. supertonic 기동
    supertonic_proc = subprocess.Popen(
        [VENV_BIN / "supertonic", "serve",
         "--host", "127.0.0.1", "--port", "7788"],
        env={**os.environ, "HF_HUB_OFFLINE": "0"},  # 첫 실행 시 모델 다운로드 허용
        stdout=supertonic_log_fd, stderr=supertonic_log_fd,
    )

    # 4. 비동기 태스크 시작
    await asyncio.gather(
        player_loop(),
        cleanup_loop(),
        monitor_children(uvicorn_proc, supertonic_proc),
    )
```

**SIGTERM / SIGINT 처리:**

```python
async def shutdown(procs):
    for proc in reversed(procs):   # supertonic → uvicorn 순서로 종료
        proc.terminate()
    # 최대 5초 대기, 응답 없으면 SIGKILL
    deadline = asyncio.get_event_loop().time() + 5
    for proc in procs:
        remaining = max(0, deadline - asyncio.get_event_loop().time())
        try:
            await asyncio.wait_for(
                asyncio.get_event_loop().run_in_executor(None, proc.wait),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            proc.kill()
```

**자식 프로세스 감시 (`monitor_children`):**
- 1초 주기로 `proc.poll()` 확인
- 자식이 비정상 종료(`returncode != 0`)되면 에러 로그 기록 후 `sys.exit(1)`
- launchd의 `SuccessfulExit=false` 조건으로 supervisor 전체 재시작

### 2. TTS Player — bash → asyncio Task 이식

현재 `tts_player.sh`의 로직을 Python asyncio Task로 포팅.

```python
async def player_loop():
    spool = Path("/tmp/tts-spool")
    spool.mkdir(exist_ok=True)
    idle = 0
    while True:
        try:
            files = sorted(
                list(spool.glob("*.wav")) + list(spool.glob("*.mp3"))
            )
            if files:
                audio = files[0]
                meta  = audio.with_suffix(".meta")
                speed = meta.read_text().strip() if meta.exists() else "1.2"
                meta.unlink(missing_ok=True)
                proc = await asyncio.create_subprocess_exec(
                    "afplay", "-r", speed, str(audio)
                )
                await proc.wait()        # 재생 완료까지 대기
                audio.unlink(missing_ok=True)
                idle = 0
            else:
                idle += 1
                delay = min(0.3 * (1.5 ** idle), 2.0)
                await asyncio.sleep(delay)
        except Exception as e:
            log.error(f"[Player] 재생 오류: {e}")
            if 'audio' in locals() and audio.exists():
                audio.unlink(missing_ok=True)
```

**stale 파일 정리 (`cleanup_loop`):**
- supervisor 시작 시 1회 즉시 실행
- 이후 30분 주기로 반복
- 5분 초과 파일 삭제 + 10개 초과 시 오래된 파일부터 제거

**중복 실행 방지:**
- bash에서 `pgrep -f tts_player.sh`로 중복 체크하던 로직 불필요
- supervisor 자체가 launchd에 의해 1개만 유지됨

### 3. server.sh 변경

**제거 함수:**
- `_supertonic_running()` — supervisor 내부에서 관리
- `_player_running()` — asyncio Task로 흡수
- `_start_player()` / `_stop_player()` — 불필요

**`_supervisor_running()` 신규:**
```bash
_supervisor_running() {
  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}
```

**`do_start()` 변경:**
```bash
do_start() {
  # launchd 관리 중이면 수동 시작 안내 후 종료 (기존 동작 유지)
  if _is_launchd_managed; then
    echo "launchd 서비스가 supervisor를 관리 중입니다."
    return 0
  fi
  if _supervisor_running; then echo "이미 실행 중"; return 0; fi
  nohup "$SCRIPT_DIR/tts-venv/bin/python" \
      "$SCRIPT_DIR/tts_server/supervisor.py" \
      >> "$LOG_FILE" 2>&1 &
  disown $!
}
```

**`do_stop()` 변경:**
```bash
do_stop() {
  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null) || return 0
  kill -TERM "$pid"   # supervisor → 자식들 연쇄 종료
  rm -f "$SCRIPT_DIR/.tts_server.pid"
}
```

**launchd plist `ProgramArguments` 변경:**
```xml
<key>ProgramArguments</key>
<array>
  <string>${SCRIPT_DIR}/tts-venv/bin/python</string>
  <string>${SCRIPT_DIR}/tts_server/supervisor.py</string>
</array>
```

**`do_status()` 변경:**
- TTS Player 항목 제거 (supervisor Task이므로 별도 상태 표시 불필요)
- Supertonic 상태는 포트 확인으로 유지

### 4. 에러 처리 매트릭스

| 상황 | 변경 전 | 변경 후 |
|------|---------|---------|
| uvicorn 크래시 | launchd → start.sh 전체 재시작 | supervisor 감지 → `sys.exit(1)` → launchd → supervisor 재시작 |
| supertonic 크래시 | 감지 안 됨 | supervisor 감지 → `sys.exit(1)` → launchd → 전체 재시작 |
| Player bash 크래시 | 감지 안 됨 (좀비 가능) | asyncio Task 예외 → 로그 기록 → 루프 계속 |
| supervisor 크래시 | 해당 없음 | launchd 재시작 (기존과 동일) |

---

## 파일 변경 요약

**신규:**
- `tts_server/supervisor.py`

**수정:**
- `server.sh` — player/supertonic 관련 함수 제거, supervisor 기반으로 전환

**삭제:**
- `tts_server/start.sh`
- `tts_server/stop.sh`
- `tts_server/supertonic_start.sh`
- `tts_server/supertonic_stop.sh`
- `tts_server/tts_player.sh`

**무변경:**
- `tts_server/server.py` — MLX 단일 워커 스레드 제약 그대로 유지
- `src/player.ts` 및 MCP 레이어 전체 — 스풀 파일 생성 경로 동일

---

## 마이그레이션 절차

1. `supervisor.py` 작성 및 수동 실행 테스트
2. `./server.sh uninstall` — 기존 launchd 등록 및 프로세스 정리
3. `./server.sh install` — supervisor 기반으로 재등록
4. 구 스크립트 삭제 (start.sh, stop.sh, supertonic_start.sh, supertonic_stop.sh, tts_player.sh)

---

## 미결 사항

없음.
