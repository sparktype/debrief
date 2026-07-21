# chorus 3차 개선 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4개 관점(아키텍처·코드품질·성능보안·기능UX) 분석에서 도출한 38개 이슈를 Sprint 1(버그·안정성)과 Sprint 2(UX·기능)로 나눠 구현한다.

**Architecture:** hook_voice Python 패키지는 매 hook 호출마다 새 프로세스로 실행되고, TTS Supervisor(supervisor.py)가 uvicorn(7777)·supertonic(7788)·Player 루프를 단일 asyncio 이벤트 루프에서 관리한다. 오디오 파일은 `/tmp/tts-spool/`에 스풀링되고 Player 루프가 순차 재생한다.

**Tech Stack:** Python 3.11+, asyncio, FastAPI, httpx, edge_tts, pytest, pytest-asyncio

---

## 파일 구조 (수정 대상)

| 파일 | Sprint | 변경 내용 |
|------|--------|---------|
| `hooks/stop.sh` | S1 | stdin payload 전달 |
| `hooks/prompt-submit.sh` | S1 | stdin payload 전달 |
| `hook_voice/__main__.py` | S1+S2 | get_running_loop, config/control/health/history 서브커맨드 |
| `hook_voice/llm_client.py` | S1 | API 키 누락 경고 |
| `hook_voice/voice_router.py` | S1 | _FALLBACK_MAP "연아" 동기화 |
| `hook_voice/player.py` | S1 | mktemp→NamedTemporaryFile, spool speed 인코딩, timeout 파라미터 |
| `hook_voice/hook_handlers.py` | S1+S2 | subagent_stop 개선, config/control/health/history 핸들러 |
| `hook_voice/last_message.py` | S2 | append_history, _rotate_history |
| `tts_server/supervisor.py` | S1 | asyncio.Event 지역화, terminate wait, spool speed 파싱, PID 파일 |
| `tests/test_hook_handlers.py` | S1 | handle_subagent_stop 테스트 |
| `classify-rules.json` | S2 | pre-tool-bash 분류 규칙 외부화 |
| `server.sh` | S2 | status 개선, install 전체 hook, pause/resume/flush/skip 래퍼 |

---

## ━━━ SPRINT 1: 버그·안정성 ━━━

---

### Task 1: hooks stdin payload 전달 (S1-1)

**Files:**
- Modify: `hooks/stop.sh`
- Modify: `hooks/prompt-submit.sh`

- [ ] **Step 1: stop.sh 수정**

```bash
# hooks/stop.sh 전체 내용으로 교체
#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice hook >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

- [ ] **Step 2: prompt-submit.sh 수정**

```bash
# hooks/prompt-submit.sh 전체 내용으로 교체
#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice hook-suggest >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

- [ ] **Step 3: 동작 확인**

```bash
echo '{"last_assistant_message":"안녕하세요 테스트입니다"}' | bash hooks/stop.sh
sleep 0.5
grep -i "hook\|안녕" /tmp/voice-notification-debug.log | tail -5
```

Expected: 로그에 handle_hook 진입 기록 확인. 빈 raw → transcript 폴백 없이 직접 텍스트 처리.

- [ ] **Step 4: 커밋**

```bash
git add hooks/stop.sh hooks/prompt-submit.sh
git commit -m "fix: stop.sh·prompt-submit.sh stdin payload 전달"
```

---

### Task 2: asyncio.get_running_loop() 교체 (S1-3)

**Files:**
- Modify: `hook_voice/__main__.py:20`

- [ ] **Step 1: 테스트 작성 (tests/test_main.py 열어서 추가)**

```python
# tests/test_main.py 에 추가
import asyncio
import sys
from unittest.mock import patch, AsyncMock
from hook_voice.__main__ import _read_stdin

async def test_read_stdin_uses_running_loop(tmp_path):
    """get_running_loop()를 사용하는지 확인 — DeprecationWarning 없이 동작."""
    with patch("sys.stdin.isatty", return_value=False), \
         patch("sys.stdin.buffer.read", return_value=b"hello"):
        result = await _read_stdin()
    assert result == "hello"
```

- [ ] **Step 2: 테스트 실행 — 현재 코드로 통과 확인**

```bash
.venv/bin/pytest tests/test_main.py::test_read_stdin_uses_running_loop -v
```

- [ ] **Step 3: __main__.py 수정**

```python
# hook_voice/__main__.py _read_stdin 함수
async def _read_stdin() -> str:
    if sys.stdin.isatty():
        return ""
    loop = asyncio.get_running_loop()  # get_event_loop() → get_running_loop()
    data = await loop.run_in_executor(None, sys.stdin.buffer.read)
    return data.decode("utf-8").strip()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_main.py -v
```

Expected: PASSED

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/__main__.py
git commit -m "fix: asyncio.get_event_loop() → get_running_loop() (Python 3.12 호환)"
```

---

### Task 3: _FALLBACK_MAP "연아" 동기화 (S1-9)

**Files:**
- Modify: `hook_voice/voice_router.py:34`
- Modify: `tests/test_voice_router.py`

- [ ] **Step 1: 실패 테스트 작성**

```python
# tests/test_voice_router.py 에 추가
from hook_voice.voice_router import _FALLBACK_MAP, resolve_voice_name

def test_fallback_map_f1_is_yeona():
    """voice-map.json 로드 실패 시 F1 이름이 '연아'여야 한다."""
    assert _FALLBACK_MAP["voice_names"]["F1"] == "연아"

def test_resolve_voice_name_fallback_uses_yeona(tmp_path):
    """voice-map.json이 없을 때 default voice 이름이 '연아'."""
    from hook_voice.voice_router import load_voice_map, resolve_voice_name
    vm = load_voice_map(tmp_path / "nonexistent.json")
    name = resolve_voice_name("unknown-agent", vm)
    assert name == "연아"
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_voice_router.py::test_fallback_map_f1_is_yeona -v
```

Expected: FAILED (AssertionError: '멜린다' != '연아')

- [ ] **Step 3: voice_router.py 수정**

`hook_voice/voice_router.py` 34번째 줄 근처:

```python
_FALLBACK_MAP: VoiceMap = {
    "supertonic": {"lang": "ko"},
    "voices": {"default": "F1"},
    "voice_names": {"F1": "연아"},  # 멜린다 → 연아 (voice-map.json과 동기화)
    "instructs": {"default": "밝고 친절하게 말해주세요"},
    "categories": {},
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_voice_router.py -v
```

Expected: 전체 PASSED

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/voice_router.py tests/test_voice_router.py
git commit -m "fix: _FALLBACK_MAP F1 이름 '멜린다' → '연아' — voice-map.json 동기화"
```

---

### Task 4: API 키 누락 경고 + 조기 반환 (S1-7)

**Files:**
- Modify: `hook_voice/llm_client.py`
- Modify: `tests/test_llm_client.py`

- [ ] **Step 1: 실패 테스트 작성**

```python
# tests/test_llm_client.py 에 추가
import logging
import pytest

async def test_chat_completion_warns_on_missing_api_key(caplog):
    """HUB_API_KEY 미설정 시 warning 로그 후 빈 문자열 반환."""
    import os
    from hook_voice.llm_client import chat_completion
    env = {k: v for k, v in os.environ.items() if k != "HUB_API_KEY"}
    with pytest.MonkeyPatch().context() as m:
        m.delenv("HUB_API_KEY", raising=False)
        with caplog.at_level(logging.WARNING, logger="hook_voice.llm_client"):
            result = await chat_completion([{"role": "user", "content": "ping"}])
    assert result == ""
    assert "HUB_API_KEY" in caplog.text
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_llm_client.py::test_chat_completion_warns_on_missing_api_key -v
```

Expected: FAILED

- [ ] **Step 3: llm_client.py 수정**

```python
# hook_voice/llm_client.py 전체
import logging
import os
import httpx

DEFAULT_MODEL = "gpt-5.4"
_log = logging.getLogger(__name__)


def _make_headers() -> dict[str, str]:
    api_key = os.environ.get("HUB_API_KEY", "")
    project_id = os.environ.get("HUB_PROJECT_ID", "")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    if project_id:
        headers["X-Project-Id"] = project_id
    return headers


async def chat_completion(
    messages: list[dict],
    model: str = DEFAULT_MODEL,
    **kwargs,
) -> str:
    """OpenAI 호환 chat completion — 응답 텍스트 반환, 실패 시 빈 문자열."""
    api_key = os.environ.get("HUB_API_KEY", "")
    if not api_key:
        _log.warning("HUB_API_KEY 미설정 — LLM 호출 건너뜀")
        return ""
    base_url = os.environ.get("HUB_BASE_URL", "")
    async with httpx.AsyncClient(
        base_url=base_url,
        headers=_make_headers(),
        verify=False,
        timeout=30.0,
    ) as client:
        try:
            resp = await client.post(
                "/chat/completions",
                json={"model": model, "messages": messages, **kwargs},
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"].strip()
        except Exception:
            return ""
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_llm_client.py -v
```

Expected: 전체 PASSED

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/llm_client.py tests/test_llm_client.py
git commit -m "fix: HUB_API_KEY 미설정 시 warning 로그 + 조기 반환"
```

---

### Task 5: asyncio.Event 지역화 + terminate wait (S1-4, S1-6)

**Files:**
- Modify: `tts_server/supervisor.py`

- [ ] **Step 1: 테스트 확인**

```bash
.venv/bin/pytest tts_server/test_supervisor.py -v
```

현재 통과하는 테스트 목록 기록.

- [ ] **Step 2: supervisor.py — _shutdown_event 모듈 레벨 제거 + main() 내부 생성**

`tts_server/supervisor.py`에서:

1. 모듈 레벨 `_shutdown_event = asyncio.Event()` 선언 삭제
2. `main()` 함수 상단에 `shutdown = asyncio.Event()` 추가
3. `player_loop()`, `cleanup_loop()`, `monitor_children()` 호출 시 `shutdown=shutdown` 명시 전달
4. 시그널 핸들러 `loop.add_signal_handler(sig, _shutdown_event.set)` → `loop.add_signal_handler(sig, shutdown.set)`

```python
async def main() -> None:
    shutdown = asyncio.Event()          # ← 여기서 생성
    PID_FILE.write_text(str(os.getpid()))
    log.info(f"[Supervisor] 시작 (PID {os.getpid()})")

    procs: list[subprocess.Popen] = []
    loop = asyncio.get_running_loop()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, shutdown.set)   # ← shutdown 참조

    try:
        uvicorn_proc = _start_uvicorn()
        procs.append(uvicorn_proc)
        log.info(f"[Supervisor] uvicorn 기동 (PID {uvicorn_proc.pid})")

        supertonic_proc = _start_supertonic()
        procs.append(supertonic_proc)
        log.info(f"[Supervisor] supertonic 기동 (PID {supertonic_proc.pid})")

        await asyncio.gather(
            player_loop(shutdown=shutdown),        # ← shutdown 전달
            cleanup_loop(shutdown=shutdown),       # ← shutdown 전달
            monitor_children(procs, shutdown=shutdown),  # ← shutdown 전달
        )
    finally:
        await _graceful_shutdown(procs)
        PID_FILE.unlink(missing_ok=True)
        if any(p.returncode not in (None, 0) for p in procs):
            sys.exit(1)
```

- [ ] **Step 3: player_loop — terminate 후 wait 추가**

`player_loop` 내 `proc.terminate()` 이후:

```python
if shutdown.is_set() and proc.returncode is None:
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=2.0)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
for t in pending:
    t.cancel()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tts_server/test_supervisor.py -v
```

Expected: 기존과 동일하게 PASSED

- [ ] **Step 5: 커밋**

```bash
git add tts_server/supervisor.py
git commit -m "fix: asyncio.Event 전역→main() 지역화, terminate 후 proc.wait() 추가"
```

---

### Task 6: spool 파일명에 speed 인코딩 (S1-5)

**Files:**
- Modify: `hook_voice/player.py` (_enqueue_spool)
- Modify: `tts_server/supervisor.py` (player_loop speed 파싱)
- Modify: `tests/test_player.py`

- [ ] **Step 1: 실패 테스트 작성**

```python
# tests/test_player.py 에 추가
from pathlib import Path
import time
from hook_voice.player import _enqueue_spool, SPOOL_DIR

def test_enqueue_spool_encodes_speed_in_filename(tmp_path):
    """_enqueue_spool이 meta 파일 대신 파일명에 speed를 인코딩한다."""
    audio = tmp_path / "test.wav"
    audio.write_bytes(b"RIFF")

    _enqueue_spool.__globals__["SPOOL_DIR"] = tmp_path  # SPOOL_DIR 임시 교체
    _enqueue_spool(audio, speed=1.25)

    spool_files = list(tmp_path.glob("*.wav"))
    meta_files = list(tmp_path.glob("*.meta"))

    assert len(spool_files) == 1
    assert len(meta_files) == 0           # meta 파일 없어야 함
    assert "_125." in spool_files[0].name  # 1.25 → 125
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_player.py::test_enqueue_spool_encodes_speed_in_filename -v
```

Expected: FAILED (meta 파일이 여전히 생성됨)

- [ ] **Step 3: player.py _enqueue_spool 수정**

```python
def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))  # 1.0→100, 1.2→120, 1.25→125
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)
    # .meta 파일 생성 없음 — speed는 파일명에 포함
```

- [ ] **Step 4: supervisor.py player_loop speed 파싱 수정**

```python
# player_loop 내부, audio 선택 직후
audio = files[0]
stem_parts = audio.stem.rsplit("_", 1)
if len(stem_parts) == 2 and stem_parts[-1].isdigit():
    speed = str(int(stem_parts[-1]) / 100)  # 120 → "1.2"
else:
    speed = "1.0"
# meta 파일 read/unlink 코드 제거
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_player.py -v
```

Expected: 전체 PASSED

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/player.py tts_server/supervisor.py tests/test_player.py
git commit -m "fix: spool .meta 파일 제거 — 파일명에 speed 인코딩으로 race condition 해소"
```

---

### Task 7: Config timeout 파라미터 적용 (S1-8)

**Files:**
- Modify: `hook_voice/player.py` (speak_hook, speak_agent 시그니처)
- Modify: `hook_voice/hook_handlers.py` (handle_hook, handle_subagent_stop)

- [ ] **Step 1: player.py speak_hook 시그니처에 edge_timeout 추가**

```python
async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2,
                     edge_timeout: float = 10.0) -> None:
    skip_edge = os.environ.get("VOICE_PERSONA_OFFLINE") == "1"
    if not skip_edge and _venv_python().exists():
        try:
            mp3 = await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)
            _enqueue_spool(mp3, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed)
```

- [ ] **Step 2: player.py speak_agent 시그니처에 supertonic_timeout 추가**

```python
async def speak_agent(text: str, voice: str, port: int, speed: float,
                      instruct: str = "", supertonic_timeout: float = 20.0) -> None:
    if not text.strip():
        return
    if await _is_supertonic_alive(port):
        try:
            wav_bytes = await asyncio.wait_for(
                _generate_supertonic(text, voice, port), timeout=supertonic_timeout
            )
            tmp = Path(tempfile.NamedTemporaryFile(delete=False, suffix=".wav", prefix="vp_st_").name)
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed, instruct)
```

- [ ] **Step 3: hook_handlers.py에서 config timeout 전달**

`handle_hook` 내:
```python
await speak_hook(summary, config.voice, config.tts_speed,
                 edge_timeout=config.edge_timeout_ms / 1000)
```

`handle_subagent_stop` 내:
```python
await speak_agent(
    f"{label} {voice_name}입니다. {one_liner}",
    voice, config.supertonic_port, config.tts_speed, instruct,
    supertonic_timeout=config.supertonic_timeout_ms / 1000,
)
```

- [ ] **Step 4: 전체 테스트 통과 확인**

```bash
.venv/bin/pytest tests/ -v
```

Expected: PASSED

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/player.py hook_voice/hook_handlers.py
git commit -m "fix: config edge_timeout_ms·supertonic_timeout_ms 실제 동작에 반영"
```

---

### Task 8: handle_subagent_stop 테스트 (S1-10)

**Files:**
- Modify: `tests/test_hook_handlers.py`

- [ ] **Step 1: 테스트 작성**

```python
# tests/test_hook_handlers.py 에 추가
import json
from unittest.mock import AsyncMock, patch, MagicMock
from hook_voice.hook_handlers import handle_subagent_stop
from hook_voice.config import Config

@pytest.fixture
def default_config():
    return Config()

async def test_subagent_stop_skips_short_text(default_config):
    """min_chars 미만 텍스트는 TTS 호출 없이 반환."""
    with patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak:
        await handle_subagent_stop("짧음", "feature-reviewer", default_config)
    mock_speak.assert_not_called()

async def test_subagent_stop_uses_correct_voice_for_reviewer(default_config):
    """feature-reviewer → M2(빌) voice 사용."""
    text = json.dumps({"last_assistant_message": "코드 리뷰를 완료했습니다. " * 5})
    with patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="리뷰 완료"):
        await handle_subagent_stop(text, "feature-reviewer", default_config)
    mock_speak.assert_called_once()
    args = mock_speak.call_args
    assert args[0][1] == "M2"  # voice = M2(빌)
    assert "리뷰어 빌입니다" in args[0][0]

async def test_subagent_stop_falls_back_to_default_on_unknown_agent(default_config):
    """알 수 없는 agent_type → default voice(F1) 사용."""
    text = "A" * 60
    with patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="완료"):
        await handle_subagent_stop(text, "unknown-xyz", default_config)
    mock_speak.assert_called_once()
    args = mock_speak.call_args
    assert args[0][1] == "F1"  # default voice

async def test_subagent_stop_empty_one_liner_still_speaks(default_config):
    """extract_one_liner가 빈 문자열 반환해도 '{label} {name}입니다.' 발화."""
    text = "B" * 60
    with patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value=""):
        await handle_subagent_stop(text, "feature-builder", default_config)
    mock_speak.assert_called_once()
    spoken = mock_speak.call_args[0][0]
    assert "빌더 리누스입니다." in spoken
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_subagent_stop_uses_correct_voice_for_reviewer -v
```

Expected: FAILED or 확인

- [ ] **Step 3: 테스트 통과 확인 (코드 변경 없이 통과해야 함)**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: 새 테스트 포함 PASSED

- [ ] **Step 4: 커밋**

```bash
git add tests/test_hook_handlers.py
git commit -m "test: handle_subagent_stop 핵심 분기 테스트 추가"
```

---

### Task 9: Sprint 1 전체 검증

- [ ] **Step 1: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 모든 테스트 PASSED

- [ ] **Step 2: TTS 동작 확인**

```bash
./server.sh status
echo '{"last_assistant_message":"스프린트 1 완료입니다. 버그 수정이 모두 적용되었습니다."}' | .venv/bin/python -m hook_voice hook
sleep 3
ls /tmp/tts-spool/
```

Expected: spool에 파일이 생성됐다 재생 후 제거됨. 파일명에 `_100.` (speed 1.0) 포함.

---

## ━━━ SPRINT 2: UX·기능 ━━━

---

### Task 10: 발화 히스토리 기록 (S2-6)

**Files:**
- Modify: `hook_voice/last_message.py`
- Modify: `hook_voice/__main__.py`
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/test_last_message.py`

- [ ] **Step 1: 실패 테스트 작성**

```python
# tests/test_last_message.py 에 추가
import json
from pathlib import Path
from hook_voice.last_message import append_history, _rotate_history, _get_history_file

def test_append_history_creates_jsonl(tmp_path, monkeypatch):
    """append_history가 history.jsonl에 타임스탬프+텍스트를 기록한다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    append_history("테스트 발화입니다")
    hist = tmp_path / "history.jsonl"
    assert hist.exists()
    entry = json.loads(hist.read_text().strip())
    assert entry["text"] == "테스트 발화입니다"
    assert "ts" in entry

def test_rotate_history_trims_to_900(tmp_path):
    """1000줄 초과 시 처음 100줄을 제거해 900줄 유지한다."""
    hist = tmp_path / "history.jsonl"
    lines = [json.dumps({"ts": f"2026-01-{i:02d}", "text": f"line{i}"}) for i in range(1001)]
    hist.write_text("\n".join(lines) + "\n")
    _rotate_history(hist)
    result = hist.read_text().splitlines()
    assert len(result) == 900
    assert "line100" in result[0]  # 처음 100줄 제거됨
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_last_message.py::test_append_history_creates_jsonl -v
```

Expected: FAILED

- [ ] **Step 3: last_message.py 수정**

```python
# hook_voice/last_message.py 에 추가 (기존 save_last_message 아래)
import json
from datetime import datetime, timezone

_HISTORY_MAX_LINES = 1000
_HISTORY_TRIM_COUNT = 100


def _get_history_file() -> Path:
    return _get_data_dir() / "history.jsonl"


def _rotate_history(hist: Path) -> None:
    try:
        lines = hist.read_text(encoding="utf-8").splitlines()
        if len(lines) > _HISTORY_MAX_LINES:
            hist.write_text(
                "\n".join(lines[_HISTORY_TRIM_COUNT:]) + "\n",
                encoding="utf-8",
            )
    except Exception:
        pass


def append_history(text: str) -> None:
    try:
        d = _get_data_dir()
        d.mkdir(parents=True, exist_ok=True)
        hist = _get_history_file()
        entry = {"ts": datetime.now(timezone.utc).isoformat(), "text": text}
        with open(hist, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        _rotate_history(hist)
    except Exception:
        pass
```

- [ ] **Step 4: save_last_message에서 append_history 호출**

```python
def save_last_message(text: str) -> None:
    try:
        d = _get_data_dir()
        d.mkdir(parents=True, exist_ok=True)
        _LAST_MSG_FILE_NAME = "last_message.txt"
        (d / _LAST_MSG_FILE_NAME).write_text(text, encoding="utf-8")
        append_history(text)   # ← 추가
    except Exception:
        pass
```

※ last_message.py의 실제 save_last_message 구현을 읽어 위치를 확인하고 append_history 호출만 삽입.

- [ ] **Step 5: __main__.py에 history 서브커맨드 추가**

```python
# __main__.py main() 내 elif 블록 추가
elif subcommand == "history":
    await handle_history(sys.argv[2:], config)
```

- [ ] **Step 6: hook_handlers.py handle_history 추가**

```python
async def handle_history(args: list[str], config: Config) -> None:
    n = 10
    if args:
        try:
            n = int(args[0])
        except ValueError:
            pass
    from .last_message import _get_history_file
    import json as _json
    hist = _get_history_file()
    if not hist.exists():
        print("발화 히스토리가 없습니다.")
        return
    lines = hist.read_text(encoding="utf-8").splitlines()
    for line in lines[-n:]:
        try:
            entry = _json.loads(line)
            ts = entry.get("ts", "")[:19].replace("T", " ")
            text = entry.get("text", "")[:80]
            print(f"  {ts}  {text}")
        except Exception:
            pass
```

- [ ] **Step 7: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_last_message.py -v
```

Expected: 전체 PASSED

- [ ] **Step 8: 동작 확인**

```bash
echo '{"last_assistant_message":"히스토리 테스트 발화입니다. 이 메시지가 기록되는지 확인합니다."}' \
  | .venv/bin/python -m hook_voice hook
.venv/bin/python -m hook_voice history 5
```

Expected: 방금 발화한 텍스트가 히스토리에 출력됨

- [ ] **Step 9: 커밋**

```bash
git add hook_voice/last_message.py hook_voice/__main__.py hook_voice/hook_handlers.py tests/test_last_message.py
git commit -m "feat: 발화 히스토리 기록 (history.jsonl) + python -m hook_voice history"
```

---

### Task 11: pre-tool-bash 위험 패턴 확장 + 외부 JSON (S2-7)

**Files:**
- Create: `classify-rules.json`
- Modify: `hook_voice/hook_handlers.py`
- Modify: `tests/test_hook_handlers.py`

- [ ] **Step 1: classify-rules.json 생성**

```json
{
  "pre_tool": [
    {"pattern": "rm\\s+-rf|git\\s+reset\\s+--hard|DROP\\s+TABLE", "message": "주의: 되돌릴 수 없는 작업입니다."},
    {"pattern": "git\\s+push.*--force", "message": "주의: 강제 push — 원격 이력이 변경됩니다."},
    {"pattern": "kubectl\\s+delete|kubectl\\s+drain", "message": "주의: 쿠버네티스 리소스를 삭제합니다."},
    {"pattern": "docker.*rm\\s+-f|docker.*rmi", "message": "주의: 컨테이너 또는 이미지를 삭제합니다."},
    {"pattern": "aws.*delete|aws.*terminate", "message": "주의: AWS 리소스를 삭제합니다."},
    {"pattern": "npm run build|tsc\\b|cargo build|go build", "message": "빌드를 시작합니다."},
    {"pattern": "npm\\s+test|vitest|pytest|cargo\\s+test|go\\s+test", "message": "테스트를 실행합니다."},
    {"pattern": "npm\\s+install|npm\\s+ci|pip\\s+install|uv\\s+sync", "message": "패키지를 설치합니다."}
  ]
}
```

- [ ] **Step 2: 실패 테스트 작성**

```python
# tests/test_hook_handlers.py 에 추가
from hook_voice.hook_handlers import classify_pre_tool_bash

def test_classify_git_push_force():
    assert classify_pre_tool_bash("git push origin main --force") == \
        "주의: 강제 push — 원격 이력이 변경됩니다."

def test_classify_kubectl_delete():
    assert classify_pre_tool_bash("kubectl delete pod my-pod") == \
        "주의: 쿠버네티스 리소스를 삭제합니다."

def test_classify_returns_none_for_unknown():
    assert classify_pre_tool_bash("echo hello world") is None
```

- [ ] **Step 3: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_classify_git_push_force -v
```

Expected: FAILED

- [ ] **Step 4: hook_handlers.py classify_pre_tool_bash 수정**

```python
_CLASSIFY_RULES_PATH = Path(__file__).parent.parent / "classify-rules.json"
_classify_rules_cache: list[dict] | None = None


def _load_classify_rules() -> list[dict]:
    global _classify_rules_cache
    if _classify_rules_cache is not None:
        return _classify_rules_cache
    try:
        data = json.loads(_CLASSIFY_RULES_PATH.read_text(encoding="utf-8"))
        _classify_rules_cache = data.get("pre_tool", [])
    except Exception:
        _classify_rules_cache = []
    return _classify_rules_cache


def classify_pre_tool_bash(cmd: str) -> str | None:
    rules = _load_classify_rules()
    if rules:
        for rule in rules:
            if re.search(rule["pattern"], cmd):
                return rule["message"]
        return None
    # JSON 없을 때 하드코딩 폴백
    if re.search(r"rm\s+-rf|git\s+reset\s+--hard|DROP\s+TABLE", cmd):
        return "주의: 되돌릴 수 없는 작업입니다."
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd):
        return "빌드를 시작합니다."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        return "테스트를 실행합니다."
    if re.search(r"npm\s+install|npm\s+ci|pip\s+install|uv\s+sync", cmd):
        return "패키지를 설치합니다."
    return None
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: 전체 PASSED

- [ ] **Step 6: 커밋**

```bash
git add classify-rules.json hook_voice/hook_handlers.py tests/test_hook_handlers.py
git commit -m "feat: pre-tool-bash 위험 패턴 확장 + classify-rules.json 외부화"
```

---

### Task 12: server.sh status 개선 + install 전체 hook 등록 (S2-3, S2-5)

**Files:**
- Modify: `server.sh`

- [ ] **Step 1: server.sh do_status 함수 개선**

`do_status` 함수에 아래 내용 추가:

```bash
# spool 큐 상태
SPOOL_DIR="/tmp/tts-spool"
if [ -d "$SPOOL_DIR" ]; then
  QUEUE_COUNT=$(ls "$SPOOL_DIR"/*.wav "$SPOOL_DIR"/*.mp3 2>/dev/null | wc -l | tr -d ' ')
else
  QUEUE_COUNT=0
fi

# 마지막 발화 텍스트
DATA_DIR="${VOICE_PERSONA_DATA_DIR:-$HOME/.local/share/voice-persona}"
LAST_MSG=""
if [ -f "$DATA_DIR/last_message.txt" ]; then
  LAST_MSG=$(head -c 60 "$DATA_DIR/last_message.txt")
fi

echo ""
echo "[TTS 큐]"
echo "  대기: ${QUEUE_COUNT}개"
if [ -n "$LAST_MSG" ]; then
  echo "  마지막 발화: $LAST_MSG"
fi
```

- [ ] **Step 2: do_install 함수 — 전체 hook 등록**

현재 stop.sh만 등록하는 코드를 아래로 교체:

```bash
# 등록할 hook 목록
SETTINGS="$HOME/.claude/settings.json"
HOOKS_JSON=$(python3 -c "
import json, sys

settings_path = '$SETTINGS'
try:
    data = json.loads(open(settings_path).read()) if __import__('os').path.exists(settings_path) else {}
except Exception:
    data = {}

if 'hooks' not in data:
    data['hooks'] = {}

hooks_dir = '$SCRIPT_DIR/hooks'

stop_cmd = f'{hooks_dir}/stop.sh'
subagent_cmd = f'{hooks_dir}/subagent-stop.sh'
notification_cmd = f'{hooks_dir}/notification.sh'
pre_cmd = f'{hooks_dir}/pre-tool-bash.sh'
post_cmd = f'{hooks_dir}/post-tool-bash.sh'
prompt_cmd = f'{hooks_dir}/prompt-submit.sh'
session_cmd = f'{hooks_dir}/session-start.sh'

def add_hook(section, entry):
    existing = data['hooks'].get(section, [])
    cmds = [h.get('command','') for h in existing if isinstance(h, dict) and 'command' in h]
    if entry['command'] not in cmds:
        existing.append(entry)
    data['hooks'][section] = existing

add_hook('Stop', {'type': 'command', 'command': stop_cmd, 'timeout': 15})
add_hook('SubagentStop', {'type': 'command', 'command': subagent_cmd, 'timeout': 15})
add_hook('Notification', {'type': 'command', 'command': notification_cmd, 'timeout': 10})
add_hook('UserPromptSubmit', {'type': 'command', 'command': prompt_cmd, 'timeout': 10})
add_hook('SessionStart', {'type': 'command', 'command': session_cmd, 'timeout': 10})

# PreToolUse/PostToolUse는 matcher 형식
for section, cmd, timeout in [('PreToolUse', pre_cmd, 10), ('PostToolUse', post_cmd, 10)]:
    existing = data['hooks'].get(section, [])
    matchers = [h.get('matcher','') for h in existing if isinstance(h, dict)]
    if 'Bash' not in matchers:
        existing.append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': cmd, 'timeout': timeout}]})
    data['hooks'][section] = existing

print(json.dumps(data, indent=2, ensure_ascii=False))
")
echo "$HOOKS_JSON" > "$SETTINGS"
echo "  → settings.json에 7종 hook 등록 완료"
```

- [ ] **Step 3: 동작 확인**

```bash
./server.sh status
```

Expected: `[TTS 큐]` 섹션이 출력됨.

```bash
./server.sh install
cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d.get('hooks',{}).keys()))"
```

Expected: `['Stop', 'SubagentStop', 'Notification', 'UserPromptSubmit', 'SessionStart', 'PreToolUse', 'PostToolUse']` (순서 무관)

- [ ] **Step 4: 커밋**

```bash
git add server.sh
git commit -m "feat: server.sh status 큐 상태 추가, install 7종 hook 일괄 등록"
```

---

### Task 13: health 진단 커맨드 (S2-4)

**Files:**
- Modify: `hook_voice/__main__.py`
- Modify: `hook_voice/hook_handlers.py`

- [ ] **Step 1: __main__.py에 health 서브커맨드 추가**

```python
elif subcommand == "health":
    await handle_health()
```

- [ ] **Step 2: hook_handlers.py handle_health 추가**

```python
async def handle_health() -> None:
    """TTS 시스템 전체 상태를 진단하고 출력한다."""
    import os as _os
    import asyncio as _asyncio

    results: list[tuple[str, str]] = []

    # 1. HUB_API_KEY
    api_key = _os.environ.get("HUB_API_KEY", "")
    results.append(("HUB_API_KEY 환경변수", "OK" if api_key else "MISSING"))

    # 2. LLM API
    if api_key:
        try:
            from .llm_client import chat_completion
            resp = await _asyncio.wait_for(
                chat_completion([{"role": "user", "content": "ping"}], max_completion_tokens=1),
                timeout=5.0,
            )
            results.append(("LLM API 연결", "OK" if resp is not None else "응답 없음"))
        except Exception as e:
            results.append(("LLM API 연결", f"FAIL ({type(e).__name__})"))
    else:
        results.append(("LLM API 연결", "SKIP (API 키 없음)"))

    # 3. uvicorn
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get("http://localhost:7777/health", timeout=2.0)
            results.append(("uvicorn (7777)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})"))
    except Exception as e:
        results.append(("uvicorn (7777)", f"FAIL ({type(e).__name__})"))

    # 4. supertonic
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get("http://localhost:7788/v1/health", timeout=2.0)
            results.append(("supertonic (7788)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})"))
    except Exception as e:
        results.append(("supertonic (7788)", f"FAIL ({type(e).__name__})"))

    # 5. spool
    from .player import SPOOL_DIR
    files = (list(SPOOL_DIR.glob("*.wav")) + list(SPOOL_DIR.glob("*.mp3"))) if SPOOL_DIR.exists() else []
    results.append(("spool 디렉토리", f"{len(files)}개 대기 ({SPOOL_DIR})"))

    print("[TTS 시스템 진단]")
    for label, status in results:
        icon = "✓" if status.startswith("OK") or "대기" in status else ("!" if "SKIP" in status else "✗")
        print(f"  [{icon}] {label}: {status}")
```

- [ ] **Step 3: hook_handlers.py import 확인**

파일 상단에 `import httpx`가 있는지 확인. 없으면 추가:
```python
import httpx
```

- [ ] **Step 4: 동작 확인**

```bash
.venv/bin/python -m hook_voice health
```

Expected:
```
[TTS 시스템 진단]
  [✓] HUB_API_KEY 환경변수: OK
  [✓] LLM API 연결: OK
  [✓] uvicorn (7777): OK (200)
  [✓] supertonic (7788): OK (200)
  [✓] spool 디렉토리: 0개 대기 (/tmp/tts-spool)
```

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/__main__.py hook_voice/hook_handlers.py
git commit -m "feat: python -m hook_voice health — TTS 시스템 진단 커맨드"
```

---

### Task 14: config CLI (S2-2)

**Files:**
- Modify: `hook_voice/__main__.py`
- Modify: `hook_voice/hook_handlers.py`

- [ ] **Step 1: __main__.py에 config 서브커맨드 추가**

```python
elif subcommand == "config":
    from pathlib import Path as _Path
    from hook_voice.config import _DEFAULT_CONFIG_PATH
    await handle_config(sys.argv[2:], _DEFAULT_CONFIG_PATH)
```

- [ ] **Step 2: hook_handlers.py handle_config 추가**

```python
async def handle_config(args: list[str], config_path: "Path") -> None:
    """CLI 설정 관리 — get/set/list/reset."""
    import json as _json
    from .config import load_config, _KEY_MAP

    if not args or args[0] == "list":
        cfg = load_config(config_path)
        print("[현재 설정]")
        for json_key, py_key in _KEY_MAP.items():
            print(f"  {json_key} = {getattr(cfg, py_key)}")
        return

    if args[0] == "get" and len(args) == 2:
        json_key = args[1]
        if json_key not in _KEY_MAP:
            print(f"알 수 없는 키: {json_key}. 사용 가능: {', '.join(_KEY_MAP)}", file=sys.stderr)
            return
        cfg = load_config(config_path)
        print(getattr(cfg, _KEY_MAP[json_key]))
        return

    if args[0] == "set" and len(args) == 3:
        json_key, raw_val = args[1], args[2]
        if json_key not in _KEY_MAP:
            print(f"알 수 없는 키: {json_key}. 사용 가능: {', '.join(_KEY_MAP)}", file=sys.stderr)
            return
        data = _json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
        if raw_val.lower() == "true":
            val: object = True
        elif raw_val.lower() == "false":
            val = False
        else:
            try:
                val = int(raw_val)
            except ValueError:
                try:
                    val = float(raw_val)
                except ValueError:
                    val = raw_val
        data[json_key] = val
        config_path.write_text(_json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  {json_key} = {val}  (저장됨)")
        return

    if args[0] == "reset":
        if config_path.exists():
            config_path.unlink()
        print("설정을 기본값으로 초기화했습니다.")
        return

    print("사용법: hook_voice config [list|get <key>|set <key> <val>|reset]", file=sys.stderr)
```

- [ ] **Step 3: 동작 확인**

```bash
.venv/bin/python -m hook_voice config list
.venv/bin/python -m hook_voice config set ttsSpeed 1.3
.venv/bin/python -m hook_voice config get ttsSpeed
.venv/bin/python -m hook_voice config reset
```

Expected: ttsSpeed=1.3이 .voice-persona.json에 저장됐다가 reset으로 파일 삭제.

- [ ] **Step 4: 커밋**

```bash
git add hook_voice/__main__.py hook_voice/hook_handlers.py
git commit -m "feat: python -m hook_voice config get/set/list/reset — CLI 설정 인터페이스"
```

---

### Task 15: control 커맨드 (S2-1)

**Files:**
- Modify: `tts_server/supervisor.py` (PID 파일 기록)
- Modify: `hook_voice/__main__.py`
- Modify: `hook_voice/hook_handlers.py`
- Modify: `server.sh`

- [ ] **Step 1: supervisor.py player_loop에 PID 파일 기록**

`player_loop` 내 `proc = await asyncio.create_subprocess_exec(...)` 직후:

```python
proc = await asyncio.create_subprocess_exec("afplay", "-r", speed, str(audio))
# 현재 재생 중인 afplay PID 기록
_pid_file = spool / ".player.pid"
try:
    _pid_file.write_text(str(proc.pid))
except Exception:
    pass
```

재생 완료(또는 종료) 직후 PID 파일 제거:

```python
audio.unlink(missing_ok=True)
try:
    _pid_file.unlink(missing_ok=True)
except Exception:
    pass
```

- [ ] **Step 2: __main__.py에 control 서브커맨드 추가**

```python
elif subcommand == "control":
    action = sys.argv[2] if len(sys.argv) > 2 else ""
    await handle_control(action)
```

- [ ] **Step 3: hook_handlers.py handle_control 추가**

```python
async def handle_control(action: str) -> None:
    """TTS 재생 제어 — pause/resume/flush/skip."""
    import os as _os
    import signal as _signal
    from .player import SPOOL_DIR

    if action == "flush":
        removed = 0
        for f in list(SPOOL_DIR.glob("*.wav")) + list(SPOOL_DIR.glob("*.mp3")):
            try:
                f.unlink()
                removed += 1
            except Exception:
                pass
        print(f"큐를 비웠습니다. ({removed}개 제거)")
        return

    pid_file = SPOOL_DIR / ".player.pid"
    if not pid_file.exists():
        print("현재 재생 중인 TTS가 없습니다.")
        return

    try:
        pid = int(pid_file.read_text().strip())
    except Exception:
        print("PID 파일을 읽을 수 없습니다.")
        return

    try:
        if action == "pause":
            _os.kill(pid, _signal.SIGSTOP)
            print(f"TTS 일시정지 (PID {pid})")
        elif action == "resume":
            _os.kill(pid, _signal.SIGCONT)
            print(f"TTS 재개 (PID {pid})")
        elif action == "skip":
            _os.kill(pid, _signal.SIGKILL)
            pid_file.unlink(missing_ok=True)
            print(f"현재 트랙 스킵 (PID {pid})")
        else:
            print("사용법: hook_voice control [pause|resume|flush|skip]", file=sys.stderr)
    except ProcessLookupError:
        print("재생 프로세스가 이미 종료됐습니다.")
        pid_file.unlink(missing_ok=True)
    except PermissionError as e:
        print(f"권한 오류: {e}", file=sys.stderr)
```

- [ ] **Step 4: server.sh에 control 래퍼 추가**

```bash
# server.sh case 문에 추가
pause)
  "$VENV_PY" -m hook_voice control pause
  ;;
resume)
  "$VENV_PY" -m hook_voice control resume
  ;;
flush)
  "$VENV_PY" -m hook_voice control flush
  ;;
skip)
  "$VENV_PY" -m hook_voice control skip
  ;;
```

- [ ] **Step 5: 동작 확인**

```bash
# TTS 재생 중 상태에서
./server.sh flush
ls /tmp/tts-spool/
```

Expected: spool 비어있음. 로그 없이 "큐를 비웠습니다." 출력.

- [ ] **Step 6: 커밋**

```bash
git add tts_server/supervisor.py hook_voice/__main__.py hook_voice/hook_handlers.py server.sh
git commit -m "feat: TTS 재생 제어 커맨드 — pause/resume/flush/skip"
```

---

### Task 16: Sprint 2 전체 검증

- [ ] **Step 1: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 전체 PASSED

- [ ] **Step 2: 설치 후 통합 확인**

```bash
./server.sh install   # 7종 hook 등록
./server.sh status    # 큐 상태 포함 출력
.venv/bin/python -m hook_voice health   # 전체 진단
.venv/bin/python -m hook_voice config list  # 현재 설정 출력
.venv/bin/python -m hook_voice history 5    # 최근 발화 5개
```

- [ ] **Step 3: Sprint 2 완료 커밋 (필요시)**

```bash
git log --oneline -10
```

---

## 검증 기준 요약

| 항목 | 확인 방법 |
|------|---------|
| Sprint 1 버그 수정 | `pytest tests/ tts_server/test_*.py -v` 전체 통과 |
| stop.sh stdin | `echo '{"last_assistant_message":"테스트"}' \| bash hooks/stop.sh` 로그 확인 |
| spool speed 인코딩 | spool 파일명에 `_100.` 포함 확인 |
| Sprint 2 기능 | `./server.sh health`, `config list`, `history`, `flush` 동작 확인 |
| 전체 hook 등록 | `cat ~/.claude/settings.json` → 7종 hook 확인 |
