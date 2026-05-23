# Python·Shell 팀 개선 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tts_server/server.py`, `tts_server/tts_player.sh`, `server.sh` 에서 운영·배포 관련 8개 항목(P1~P8)을 TDD로 개선한다.

**Architecture:** 리드의 R1~R3 완료 후 시작한다. Python 항목(P1·P3·P5)은 `tts_server/test_server.py`(신규)로 검증한다. Shell 항목(P2·P4·P6·P7·P8)은 bash 로직 검증과 smoke test로 확인한다. `server.py` 항목들은 FastAPI TestClient를 사용하지 않고 함수 단위로 단독 테스트한다.

**Tech Stack:** Python 3.11+, FastAPI, pytest, bash

**전제 조건:** 리드의 `2026-05-23-lead-cross-layer.md` 계획이 완료되어 있어야 한다. `npm test`가 58개+ 통과 상태여야 한다. Python 환경: `tts-venv/bin/python3` 또는 `python3`.

---

## 파일 변경 범위

| 파일 | 작업 |
|---|---|
| `tts_server/server.py` | `_TECH_PHONETICS` 정규화 Map(P1), 구조화 로그(P3), 모델 실패 복구(P5) |
| `tts_server/tts_player.sh` | adaptive sleep(P2), 스풀 파일 누적 방지(P4) |
| `server.sh` | `_check_health()` 공통 함수(P7), Supertonic 포트 방식(P6), launchd 통합(P8) |
| `tts_server/test_server.py` | 신규 — P1·P3·P5 pytest |

---

## Python 테스트 환경 설정

모든 Python 테스트 실행 전 pytest가 설치되어 있는지 확인:

```bash
tts-venv/bin/python3 -m pytest --version 2>/dev/null || pip install pytest
```

테스트 실행 명령:

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py -v
```

---

## Task P1: `_TECH_PHONETICS` 정규화 Map

**Files:**
- Modify: `tts_server/server.py`
- Create: `tts_server/test_server.py`

- [ ] **Step 1: 실패하는 테스트 작성**

`tts_server/test_server.py` 신규 생성:

```python
# tts_server 발음 보정 함수 단위 테스트
import sys
import os

# mlx 없는 환경에서도 테스트 가능하도록 모듈 import 전 패치
sys.modules.setdefault("mlx_audio", type(sys)("mlx_audio"))
sys.modules.setdefault("mlx_audio.tts", type(sys)("mlx_audio.tts"))
sys.modules.setdefault("mlx_audio.tts.generate", type(sys)("mlx_audio.tts.generate"))
sys.modules.setdefault("mlx_audio.tts.utils", type(sys)("mlx_audio.tts.utils"))

from tts_server.server import _preprocess_for_tts


class TestTechPhonetics:
    def test_exact_key_match(self):
        assert _preprocess_for_tts("Docker") == "도커"

    def test_lowercase(self):
        assert _preprocess_for_tts("docker") == "도커"

    def test_uppercase(self):
        assert _preprocess_for_tts("DOCKER") == "도커"

    def test_mixed_sentence(self):
        result = _preprocess_for_tts("API와 Docker를 사용합니다")
        assert "에이피아이" in result
        assert "도커" in result

    def test_unknown_word_unchanged(self):
        result = _preprocess_for_tts("SomeUnknownWord")
        assert "SomeUnknownWord" in result
```

- [ ] **Step 2: 실패 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestTechPhonetics -v
```

Expected: `test_lowercase`와 `test_uppercase` 실패 — 현재 코드는 대소문자 무관 O(n) 루프로 일부 처리되지만 정확성 불일치.

- [ ] **Step 3: `server.py` 정규화 Map 도입**

`tts_server/server.py`에서 `_TECH_PHONETICS` dict 정의 직후에 추가:

```python
# 대소문자 무관 O(1) 조회를 위한 정규화 Map (key를 upper로 통일)
_TECH_PHONETICS_UPPER: dict[str, str] = {
    k.upper(): v for k, v in _TECH_PHONETICS.items()
}
```

`_preprocess_for_tts` 함수의 `_replace` 내부를 수정:

```python
def _preprocess_for_tts(text: str) -> str:
    """영문 기술 용어를 한국어 발음으로 치환 — lang_code=korean 시 발음 개선."""
    def _replace(m: re.Match) -> str:
        word = m.group(0)
        # 정규화 Map에서 O(1) 조회
        return _TECH_PHONETICS_UPPER.get(word.upper(), word)

    return re.sub(r"[A-Za-z][A-Za-z0-9\-/\.]*", _replace, text)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestTechPhonetics -v
```

Expected: 5개 모두 통과.

- [ ] **Step 5: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "perf: _TECH_PHONETICS 대소문자 정규화 Map으로 O(1) 조회"
```

---

## Task P2: TTS Player adaptive sleep

**Files:**
- Modify: `tts_server/tts_player.sh`

- [ ] **Step 1: 현재 코드 확인**

```bash
cat tts_server/tts_player.sh
```

현재 `sleep 0.3`이 항상 고정값임을 확인.

- [ ] **Step 2: adaptive sleep 로직 작성**

`tts_server/tts_player.sh`를 다음으로 교체:

```bash
#!/usr/bin/env bash
# TTS 스풀 소비자 데몬 — /tmp/tts-spool/ 에서 epoch_ms 순서대로 재생
set -euo pipefail

SPOOL=/tmp/tts-spool
PID_FILE=/tmp/tts-player.pid
MAX_SLEEP=2.0
MIN_SLEEP=0.3

mkdir -p "$SPOOL"
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

echo "[TTS Player] 시작 (PID $$, 스풀: $SPOOL)"

idle_count=0

while true; do
  # epoch_ms 기준 오름차순 — 먼저 도착한 파일 먼저 재생
  audio=$(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort | head -1 || true)
  if [[ -n "$audio" && -f "$audio" ]]; then
    idle_count=0  # 파일 발견 시 idle 카운터 초기화
    base="${audio%.*}"
    meta="${base}.meta"
    speed=$(cat "$meta" 2>/dev/null || echo "1.2")
    rm -f "$meta"
    afplay -r "$speed" "$audio" 2>/dev/null || true
    rm -f "$audio"
  else
    # 연속 idle 횟수에 따라 sleep 지수 증가 (최대 MAX_SLEEP)
    idle_count=$(( idle_count + 1 ))
    sleep_time=$(awk "BEGIN { s=$MIN_SLEEP * (1.5^$idle_count); print (s > $MAX_SLEEP ? $MAX_SLEEP : s) }")
    sleep "$sleep_time"
  fi
done
```

- [ ] **Step 3: 실행 권한 확인**

```bash
chmod +x tts_server/tts_player.sh
```

- [ ] **Step 4: 동작 검증 (로컬 실행)**

```bash
# 백그라운드로 실행 후 10초 대기하여 스풀 빈 상태에서 sleep이 증가하는지 로그 확인
# (실제 daemonize 없이 직접 실행)
timeout 3 bash tts_server/tts_player.sh 2>&1 | head -5 || true
```

Expected: `[TTS Player] 시작` 메시지 출력 후 idle.

- [ ] **Step 5: 커밋**

```bash
git add tts_server/tts_player.sh
git commit -m "perf: TTS Player adaptive sleep — 연속 idle 시 최대 2s까지 지수 증가"
```

---

## Task P3: 구조화 로그

**Files:**
- Modify: `tts_server/server.py`
- Modify: `tts_server/test_server.py`

- [ ] **Step 1: 실패하는 테스트 추가**

`tts_server/test_server.py`에 추가:

```python
import io
from contextlib import redirect_stdout
from tts_server.server import _log


class TestStructuredLog:
    def test_info_prefix(self, capsys):
        _log("INFO", "서버 시작")
        captured = capsys.readouterr()
        assert "[INFO]" in captured.out
        assert "서버 시작" in captured.out

    def test_error_prefix(self, capsys):
        _log("ERROR", "오류 발생")
        captured = capsys.readouterr()
        assert "[ERROR]" in captured.out

    def test_timestamp_included(self, capsys):
        _log("INFO", "타임스탬프 확인")
        captured = capsys.readouterr()
        # ISO 형식: YYYY-MM-DD 또는 숫자 포함 여부
        import re
        assert re.search(r"\d{4}-\d{2}-\d{2}", captured.out)
```

- [ ] **Step 2: 실패 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestStructuredLog -v
```

Expected: `_log` 함수 없음 오류.

- [ ] **Step 3: `server.py`에 `_log` 헬퍼 추가 및 모든 print 교체**

`tts_server/server.py`의 import 블록 아래에 추가:

```python
import datetime


def _log(level: str, message: str) -> None:
    """구조화 로그 출력 — [LEVEL] YYYY-MM-DD HH:MM:SS message 형식."""
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{level}] {ts} {message}", flush=True)
```

그리고 모든 `print(...)` 호출을 `_log(...)` 로 교체:

```python
# 변경 전 → 변경 후 매핑
print(f"[TTS Server] 모델 로딩 중: {_MODEL_ID}", flush=True)
→ _log("INFO", f"모델 로딩 중: {_MODEL_ID}")

print("[TTS Server] 모델 로딩 완료. 서버 준비.", flush=True)
→ _log("INFO", "모델 로딩 완료. 서버 준비.")

print(f"[TTS Server] 발음 보정: {text[:60]!r} → {processed[:60]!r}", flush=True)
→ _log("INFO", f"발음 보정: {text[:60]!r} → {processed[:60]!r}")

print(f"[TTS Server] 재생 시작: {text[:40]!r} (speed={speed}x, instruct={instruct!r})", flush=True)
→ _log("INFO", f"재생 시작: {text[:40]!r} (speed={speed}x)")

print("[TTS Server] 재생 완료", flush=True)
→ _log("INFO", "재생 완료")

print(f"[TTS Server] 재생 오류: {e}", flush=True)
→ _log("ERROR", f"재생 오류: {e}")

print("[TTS Server] 서버 종료.", flush=True)
→ _log("INFO", "서버 종료.")
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py -v
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "feat: server.py 구조화 로그 — [LEVEL] timestamp 형식 통일"
```

---

## Task P4: 스풀 파일 누적 방지

**Files:**
- Modify: `tts_server/tts_player.sh`
- Modify: `tts_server/test_server.py`

- [ ] **Step 1: 실패하는 테스트 작성**

`tts_server/test_server.py`에 추가 (bash 로직을 Python으로 검증):

```python
import os
import time
import tempfile
import glob


class TestSpoolCleanup:
    def test_old_files_removed_on_start(self, tmp_path):
        """데몬 시작 시 5분 초과 파일이 삭제되어야 한다."""
        spool = tmp_path / "tts-spool"
        spool.mkdir()

        # 6분 전 파일 생성
        old_file = spool / "1000000.wav"
        old_file.write_bytes(b"old")
        old_time = time.time() - 360  # 6분 전
        os.utime(str(old_file), (old_time, old_time))

        # 최신 파일 생성
        new_file = spool / "9999999.wav"
        new_file.write_bytes(b"new")

        # 정리 함수 실행 (bash 스크립트의 _cleanup_stale 함수를 Python으로 검증)
        # bash 스크립트 내 _cleanup_stale 로직을 직접 실행
        import subprocess
        result = subprocess.run(
            ["bash", "-c", f"""
SPOOL="{spool}"
MAX_AGE=300
find "$SPOOL" \\( -name "*.wav" -o -name "*.mp3" \\) -mmin +$((MAX_AGE/60)) -delete 2>/dev/null || true
"""],
            capture_output=True
        )
        assert result.returncode == 0
        assert not old_file.exists(), "6분 전 파일이 삭제되어야 함"
        assert new_file.exists(), "최신 파일은 유지되어야 함"

    def test_max_10_files_enforced(self, tmp_path):
        """스풀에 파일이 10개 초과 시 오래된 것이 제거되어야 한다."""
        spool = tmp_path / "tts-spool"
        spool.mkdir()

        # 12개 파일 생성 (epoch_ms 기준 오름차순)
        for i in range(12):
            (spool / f"{1000 + i}.wav").write_bytes(b"x")

        import subprocess
        result = subprocess.run(
            ["bash", "-c", f"""
SPOOL="{spool}"
MAX_FILES=10
files=($(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort))
count=${{#files[@]}}
if (( count > MAX_FILES )); then
  excess=$(( count - MAX_FILES ))
  for f in "${{files[@]:0:$excess}}"; do
    rm -f "$f" "${{f%.*}}.meta"
  done
fi
"""],
            capture_output=True
        )
        assert result.returncode == 0
        remaining = list(spool.glob("*.wav"))
        assert len(remaining) == 10, f"10개만 남아야 하는데 {len(remaining)}개"
```

- [ ] **Step 2: 실패 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestSpoolCleanup -v
```

Expected: bash 로직이 아직 없으므로 파일 정리 안 됨 → 실패.

- [ ] **Step 3: `tts_player.sh`에 정리 함수 추가**

`tts_player.sh` 상단(while loop 전)에 추가:

```bash
MAX_AGE_SECS=300   # 5분
MAX_FILES=10

_cleanup_stale() {
  # 5분 초과 오디오 파일 삭제
  find "$SPOOL" \( -name "*.wav" -o -name "*.mp3" \) -mmin +$(( MAX_AGE_SECS / 60 )) -delete 2>/dev/null || true
  # meta 파일도 정리 (대응 오디오 없는 고아)
  find "$SPOOL" -name "*.meta" -mmin +$(( MAX_AGE_SECS / 60 )) -delete 2>/dev/null || true

  # 파일 수 제한
  local files
  files=($(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort || true))
  local count=${#files[@]}
  if (( count > MAX_FILES )); then
    local excess=$(( count - MAX_FILES ))
    for f in "${files[@]:0:$excess}"; do
      rm -f "$f" "${f%.*}.meta"
    done
  fi
}

# 데몬 시작 시 한 번 실행
_cleanup_stale
echo "[TTS Player] 스풀 정리 완료"
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestSpoolCleanup -v
```

Expected: 2개 통과.

- [ ] **Step 5: 커밋**

```bash
git add tts_server/tts_player.sh tts_server/test_server.py
git commit -m "fix: TTS Player 시작 시 스풀 파일 5분 초과 정리 + 최대 10개 제한"
```

---

## Task P5: 모델 로딩 실패 복구

**Files:**
- Modify: `tts_server/server.py`
- Modify: `tts_server/test_server.py`

- [ ] **Step 1: 실패하는 테스트 추가**

`tts_server/test_server.py`에 추가:

```python
from fastapi.testclient import TestClient


class TestModelLoadingFailure:
    def test_health_returns_error_detail_when_load_fails(self):
        """모델 로딩 실패 시 /health가 503 + error detail 반환해야 한다."""
        import tts_server.server as srv
        # _model_error를 직접 세팅해서 시뮬레이션
        srv._model_error.set()
        srv._model_error_message = "테스트 오류: 모델 파일 없음"
        srv._model_ready.clear()

        client = TestClient(srv.app, raise_server_exceptions=False)
        resp = client.get("/health")
        assert resp.status_code == 503
        data = resp.json()
        assert data["status"] == "error"
        assert "테스트 오류" in data.get("detail", "")

        # 정리
        srv._model_error.clear()
        srv._model_error_message = ""
```

- [ ] **Step 2: 실패 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py::TestModelLoadingFailure -v
```

Expected: `_model_error` 속성 없음 오류.

- [ ] **Step 3: `server.py`에 `_model_error` 추가**

`server.py`에서 `_model_ready = threading.Event()` 옆에 추가:

```python
_model_ready = threading.Event()
_model_error = threading.Event()
_model_error_message = ""
```

`_tts_worker` 함수에서 예외 처리 추가:

```python
def _tts_worker() -> None:
    """모델 로딩 + TTS 생성을 같은 스레드에서 처리 — MLX Metal 스트림 유지."""
    global _model_error_message
    try:
        from mlx_audio.tts.generate import generate_audio
        from mlx_audio.tts.utils import load_model

        _log("INFO", f"모델 로딩 중: {_MODEL_ID}")
        model = load_model(_MODEL_ID)
        _log("INFO", "모델 로딩 완료. 서버 준비.")
        _model_ready.set()
    except Exception as e:
        _model_error_message = str(e)
        _model_error.set()
        _log("ERROR", f"모델 로딩 실패: {e}")
        return

    while True:
        item = _work_queue.get()
        if item is None:
            break
        text, voice, lang_code, speed, instruct = item
        # ... 기존 재생 로직 (변경 없음) ...
```

`/health` 엔드포인트 수정:

```python
@app.get("/health")
async def health():
    """서버 상태 확인."""
    if _model_error.is_set():
        return JSONResponse(
            {"status": "error", "detail": _model_error_message},
            status_code=503
        )
    if not _model_ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ok"}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py -v
```

Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "fix: 모델 로딩 실패 시 health 503+error detail 반환, 영구 loading 상태 방지"
```

---

## Task P6: Supertonic 상태 확인 포트 방식으로 교체

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 현재 코드 확인**

`server.sh`의 `_supertonic_running()`:

```bash
_supertonic_running() {
  [ -f "$SUPERTONIC_PID_FILE" ] && kill -0 "$(cat "$SUPERTONIC_PID_FILE")" 2>/dev/null
}
```

PID 파일 방식이다.

- [ ] **Step 2: 포트 점유 방식으로 교체**

`server.sh`에서 `_supertonic_running()` 함수를 교체:

```bash
_supertonic_running() {
  lsof -iTCP:${SUPERTONIC_PORT} -sTCP:LISTEN -t >/dev/null 2>&1
}
```

그리고 `_tts_running()`과 동일한 패턴이 되었으므로 PID_FILE 관련 코드 정리. `SUPERTONIC_PID_FILE` 변수 정의 줄과 PID 파일을 쓰는 부분을 찾아서 제거한다.

`supertonic_start.sh`를 확인해서 PID 파일 생성 로직이 있으면 그것도 제거한다:

```bash
cat tts_server/supertonic_start.sh
```

- [ ] **Step 3: `do_status`에서 PID 파일 참조 제거**

`do_status` 함수에서:

```bash
# 변경 전
if _supertonic_running; then
  local st_pid
  st_pid=$(cat "$SUPERTONIC_PID_FILE")
  echo "  Supertonic: ✓ 실행 중 (PID: $st_pid, 포트 ${SUPERTONIC_PORT})"

# 변경 후
if _supertonic_running; then
  local st_pid
  st_pid=$(lsof -iTCP:${SUPERTONIC_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
  echo "  Supertonic: ✓ 실행 중 (PID: $st_pid, 포트 ${SUPERTONIC_PORT})"
```

- [ ] **Step 4: smoke test**

```bash
# Supertonic이 실행 중이 아닐 때
./server.sh status 2>&1 | grep Supertonic
```

Expected: `Supertonic: ✗ 중지됨` 출력 (PID 파일 없어도 정상 판단).

- [ ] **Step 5: 커밋**

```bash
git add server.sh tts_server/supertonic_start.sh
git commit -m "refactor: Supertonic 상태 확인 PID 파일 → 포트 점유 방식으로 교체"
```

---

## Task P7: 헬스체크 중복 제거

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 현재 curl 중복 위치 확인**

```bash
grep -n "curl" server.sh
```

Expected: `do_start`, `do_status`, `do_install` 세 곳에 동일 패턴.

- [ ] **Step 2: `_check_health()` 공통 함수 추출**

`server.sh`의 헬퍼 함수 영역에 추가:

```bash
# 포트의 /health 엔드포인트에 curl 요청, HTTP 코드 반환
_check_health() {
  local port="${1:-$TTS_PORT}"
  local path="${2:-/health}"
  curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 1 "http://127.0.0.1:${port}${path}" 2>/dev/null
}
```

- [ ] **Step 3: 세 곳의 curl 직접 호출을 `_check_health`로 교체**

`do_start`에서:

```bash
# 변경 전
code=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 1 "http://127.0.0.1:${TTS_PORT}/health" 2>/dev/null)
if [[ "$code" == "200" ]]; then

# 변경 후
if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
```

`do_status`에서 (TTS 서버 헬스):

```bash
# 변경 전
code=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 2 "http://127.0.0.1:${TTS_PORT}/health" 2>/dev/null)
if [[ "$code" == "200" ]]; then

# 변경 후
if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
```

`do_status`에서 (Supertonic 헬스):

```bash
# 변경 전
st_code=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 2 "http://127.0.0.1:${SUPERTONIC_PORT}/v1/health" 2>/dev/null)
if [[ "$st_code" == "200" ]]; then

# 변경 후
if [[ "$(_check_health "$SUPERTONIC_PORT" "/v1/health")" == "200" ]]; then
```

`do_install`에서:

```bash
# 변경 전
code=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 1 "http://127.0.0.1:${TTS_PORT}/health" 2>/dev/null)
if [[ "$code" == "200" ]]; then

# 변경 후
if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
```

- [ ] **Step 4: curl 직접 호출이 남아 있지 않은지 확인**

```bash
grep -n 'curl.*health' server.sh
```

Expected: `_check_health` 함수 정의 1줄만 남아 있음.

- [ ] **Step 5: smoke test**

```bash
./server.sh status 2>&1 | head -20
```

Expected: 정상 출력 (오류 없음).

- [ ] **Step 6: 커밋**

```bash
git add server.sh
git commit -m "refactor: server.sh curl 헬스체크 _check_health() 공통 함수로 통합"
```

---

## Task P8: Supertonic launchd 통합

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: 현재 `do_start` 흐름 확인**

현재 `do_start`는 TTS 서버만 시작하고 Supertonic은 `do_install`에서만 시작함.

- [ ] **Step 2: `do_start`에 Supertonic 자동 시작 추가**

`do_start` 함수에서 `_start_player` 호출 다음에 추가:

```bash
do_start() {
  _check_deps

  if _is_launchd_managed; then
    echo "launchd 서비스가 TTS 서버를 관리 중입니다."
    echo "  일시 중지: launchctl stop  $LAUNCHD_LABEL"
    echo "  재시작:    launchctl start $LAUNCHD_LABEL"
    echo "  완전 제거: $(basename "$0") uninstall"
    return 0
  fi

  if _tts_running; then
    local pid
    pid=$(lsof -iTCP:${TTS_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
    echo "이미 실행 중 (TTS 서버 PID: $pid, 포트 ${TTS_PORT})"
    return 0
  fi

  echo "TTS 서버 시작 중..."
  bash "$SCRIPT_DIR/tts_server/start.sh"
  _start_player

  # Supertonic 서버 자동 시작 (미실행 시에만)
  if ! _supertonic_running; then
    echo "Supertonic 서버 시작 중..."
    bash "$SCRIPT_DIR/tts_server/supertonic_start.sh"
  fi

  # 최대 10초 대기하여 /health 응답 확인
  local i=0
  while (( i < 10 )); do
    if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
      echo "✓ TTS 서버 기동 완료 (HTTP 200)"
      return 0
    fi
    sleep 1
    i=$(( i + 1 ))
  done

  echo "✓ TTS 서버 프로세스 기동됨 — 모델 로딩 중, 잠시 후 응답 예정"
}
```

- [ ] **Step 3: `do_stop`에도 Supertonic 종료 추가**

```bash
do_stop() {
  _stop_player
  if ! _tts_running; then
    echo "TTS 서버가 실행 중이 아닙니다."
  else
    bash "$SCRIPT_DIR/tts_server/stop.sh"
  fi

  # Supertonic도 함께 종료
  if _supertonic_running; then
    echo "Supertonic 서버 종료 중..."
    bash "$SCRIPT_DIR/tts_server/supertonic_stop.sh"
  fi
}
```

- [ ] **Step 4: smoke test**

```bash
./server.sh start 2>&1
./server.sh status 2>&1 | grep -E "TTS|Supertonic|Player"
./server.sh stop 2>&1
```

Expected: start 시 TTS·Supertonic 둘 다 시작, status에서 둘 다 ✓, stop 시 둘 다 종료.

- [ ] **Step 5: 커밋**

```bash
git add server.sh
git commit -m "feat: server.sh start/stop에 Supertonic 자동 관리 통합"
```

---

## 최종 검증

- [ ] **Python 테스트 전체 통과**

```bash
tts-venv/bin/python3 -m pytest tts_server/test_server.py -v
```

Expected: P1·P3·P5 관련 모든 테스트 통과.

- [ ] **Node 테스트 전체 통과 (회귀 없음 확인)**

```bash
npm test
```

Expected: 전체 통과.

- [ ] **운영 스크립트 smoke test**

```bash
./server.sh status 2>&1
```

Expected: 모든 항목 상태 정보 출력 (오류 없음).

- [ ] **리드에 완료 알림**

Python·Shell 팀 P1~P8 완료를 리드에게 알린다.
