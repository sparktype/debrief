# Monitor 리뷰어 목소리 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude가 `Monitor` 도구를 호출한 응답이 완료될 때 기본 F1(연아) 대신 M2(빌/리뷰어) 목소리로 발화한다.

**Architecture:** PreToolUse hook이 Monitor 도구 감지 시 세션 기반 플래그 파일(`/tmp/tts-monitor-{session_id}`)을 생성하고, Stop hook이 이 플래그를 확인해 speak_agent(M2)를 호출한 뒤 플래그를 삭제한다.

**Tech Stack:** Python 3.11+, asyncio, pytest, Claude Code hooks (PreToolUse/Stop)

---

### Task 1: `handle_pre_tool_monitor()` — 테스트 작성 및 구현

**Files:**
- Modify: `tests/test_hook_handlers.py` (맨 끝에 추가)
- Modify: `hook_voice/hook_handlers.py` (함수 추가 + import 추가)
- Modify: `hook_voice/__main__.py` (subcommand 추가)

- [ ] **Step 1: 실패할 테스트 작성**

`tests/test_hook_handlers.py` 맨 끝에 추가:

```python
# ── handle_pre_tool_monitor 테스트 ───────────────────────────

from hook_voice.hook_handlers import handle_pre_tool_monitor


async def test_handle_pre_tool_monitor_creates_flag(monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "test-mon-001")
    flag = Path("/tmp/tts-monitor-test-mon-001")
    flag.unlink(missing_ok=True)
    try:
        await handle_pre_tool_monitor("")
        assert flag.exists()
    finally:
        flag.unlink(missing_ok=True)


async def test_handle_pre_tool_monitor_no_session_id(monkeypatch):
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    # 세션 ID 없으면 아무 파일도 생성하지 않는다
    await handle_pre_tool_monitor("")  # 예외 없이 종료되어야 함
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_handle_pre_tool_monitor_creates_flag -v
```

예상: `ImportError: cannot import name 'handle_pre_tool_monitor'`

- [ ] **Step 3: `hook_handlers.py`에 함수 구현**

`hook_voice/hook_handlers.py` 맨 끝에 추가:

```python
async def handle_pre_tool_monitor(raw: str) -> None:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session_id:
        return
    Path(f"/tmp/tts-monitor-{session_id}").touch()
```

- [ ] **Step 4: `__main__.py` subcommand 등록**

`hook_voice/__main__.py`의 import에 `handle_pre_tool_monitor` 추가:

```python
from .hook_handlers import (
    handle_hook,
    handle_notification,
    handle_subagent_stop,
    handle_hook_suggest,
    handle_pre_tool_bash,
    handle_post_tool_bash,
    handle_history,
    handle_health,
    handle_config,
    handle_control,
    handle_grafana,
    handle_pre_tool_monitor,   # 추가
)
```

`main()` 함수의 subcommand 분기에 추가 (`elif subcommand == "grafana":` 앞):

```python
    elif subcommand == "pre-tool-monitor":
        await handle_pre_tool_monitor(raw)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_handle_pre_tool_monitor_creates_flag tests/test_hook_handlers.py::test_handle_pre_tool_monitor_no_session_id -v
```

예상: 2 passed

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/hook_handlers.py hook_voice/__main__.py tests/test_hook_handlers.py
git commit -m "feat: handle_pre_tool_monitor — Monitor 도구 감지 시 세션 플래그 생성"
```

---

### Task 2: `handle_hook()` — Monitor 플래그 감지 및 M2 발화

**Files:**
- Modify: `tests/test_hook_handlers.py`
- Modify: `hook_voice/hook_handlers.py` — `handle_hook()` 수정

- [ ] **Step 1: 실패할 테스트 작성**

`tests/test_hook_handlers.py`의 기존 `MOCK_VOICE_MAP` 변수 아래에 voice_settings를 추가한 버전 정의:

```python
MOCK_VOICE_MAP_WITH_SETTINGS = {
    **MOCK_VOICE_MAP,
    "voice_settings": {
        "M2": {"synth_speed": 0.93, "steps": 10},
    },
    "categories": {
        "reviewer": ["code-reviewer"],
    },
}
```

그 아래에 테스트 추가:

```python
async def test_handle_hook_uses_reviewer_voice_when_monitor_flag(monkeypatch):
    """Monitor 플래그 파일이 있으면 speak_agent(M2)를 호출하고 플래그를 삭제한다."""
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "test-mon-002")
    flag = Path("/tmp/tts-monitor-test-mon-002")
    flag.touch()
    raw = json.dumps({"last_assistant_message": "모니터링 결과입니다. " * 6})
    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="모니터링 요약")), \
         patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP_WITH_SETTINGS), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_agent, \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_hook:
        await handle_hook(raw, _CFG)
    mock_agent.assert_called_once()
    call_kwargs = mock_agent.call_args
    assert call_kwargs.kwargs.get("voice") == "M2" or call_kwargs.args[1] == "M2"
    mock_hook.assert_not_called()
    assert not flag.exists()


async def test_handle_hook_uses_default_voice_without_monitor_flag(monkeypatch):
    """Monitor 플래그 파일이 없으면 speak_hook(F1)을 호출한다."""
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "test-mon-003")
    flag = Path("/tmp/tts-monitor-test-mon-003")
    flag.unlink(missing_ok=True)
    raw = json.dumps({"last_assistant_message": "일반 응답입니다. " * 6})
    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="일반 요약")), \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_hook, \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_agent:
        await handle_hook(raw, _CFG)
    mock_hook.assert_called_once()
    mock_agent.assert_not_called()
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_handle_hook_uses_reviewer_voice_when_monitor_flag -v
```

예상: FAIL — speak_agent가 아닌 speak_hook이 호출됨

- [ ] **Step 3: `handle_hook()` 수정**

`hook_voice/hook_handlers.py`의 `handle_hook()` 함수에서 `speak_hook(summary, ...)` 호출 부분을 아래로 교체:

```python
async def handle_hook(raw: str, config: Config) -> None:
    hook_ctx = get_or_create_context()
    log_event("hook_start", hook_ctx, {"source": "stop_hook"})
    get_registry().record_event("hook", "stop")

    text = ""
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", "")
    except Exception:
        pass
    if not text:
        tp = _derive_transcript_path()
        if tp:
            text = get_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        if config.speech_retouch:
            pipeline = get_default_pipeline()
            speech_ctx = await pipeline.process(summary)
            summary = speech_ctx.text

        session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        monitor_flag = Path(f"/tmp/tts-monitor-{session_id}") if session_id else None
        use_reviewer = bool(monitor_flag and monitor_flag.exists())

        start = _time.time()
        try:
            if use_reviewer:
                monitor_flag.unlink(missing_ok=True)
                vm = load_voice_map()
                settings = resolve_voice_settings("code-reviewer", vm)
                instruct = resolve_instruct("code-reviewer", vm)
                await speak_agent(
                    summary, "M2",
                    port=config.supertonic_port, speed=config.tts_speed,
                    instruct=instruct,
                    steps=settings["steps"],
                    synth_speed=settings["synth_speed"],
                    supertonic_timeout=config.supertonic_timeout_ms / 1000,
                )
            else:
                await speak_hook(summary, config.tts_speed)
            latency_ms = (_time.time() - start) * 1000
            get_registry().record_tts_latency(latency_ms)
            log_event("tts_completed", hook_ctx, {
                "latency_ms": round(latency_ms, 1),
                "text_len": len(summary),
            })
        except Exception as exc:
            log_event("tts_failed", hook_ctx, {"error": str(exc)}, level="WARNING")
            get_dlq_store().push(
                event_id=hook_ctx.correlation_id,
                failure_stage="speak_hook",
                failure_detail=str(exc),
                raw_text=summary[:200],
                source="stop_hook",
            )
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_handle_hook_uses_reviewer_voice_when_monitor_flag tests/test_hook_handlers.py::test_handle_hook_uses_default_voice_without_monitor_flag -v
```

예상: 2 passed

- [ ] **Step 5: 기존 테스트 전체 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

예상: 전체 passed (기존 테스트 깨지지 않음)

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/hook_handlers.py tests/test_hook_handlers.py
git commit -m "feat: handle_hook — Monitor 플래그 감지 시 M2(리뷰어) 목소리로 발화"
```

---

### Task 3: hook 스크립트 및 settings.json 등록

**Files:**
- Create: `hooks/pre-tool-monitor.sh`
- Modify: `.claude/settings.json`

- [ ] **Step 1: `hooks/pre-tool-monitor.sh` 생성**

```bash
#!/bin/bash
# Claude Code PreToolUse hook — Monitor 도구 호출 시 리뷰어 플래그 설정
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice pre-tool-monitor >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

실행 권한 부여:

```bash
chmod +x hooks/pre-tool-monitor.sh
```

- [ ] **Step 2: `.claude/settings.json`에 PreToolUse hook 등록**

현재 `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [...]
  }
}
```

`hooks` 블록을 추가 (PROJECT_DIR은 실제 경로로 교체):

```json
{
  "permissions": {
    "allow": [
      "Bash(kubectl get *)",
      "Bash(kubectl logs *)",
      "Bash(qlmanage -p *)",
      "Bash(helm show *)",
      "Bash(helm template *)",
      "mcp__mcp-k8s__list-k8s-resources"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Monitor",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/hmc7102758/Develop/Workspaces/chorus/hooks/pre-tool-monitor.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: 수동 동작 확인**

플래그 파일이 올바르게 생성되는지 직접 테스트:

```bash
CLAUDE_CODE_SESSION_ID=manual-test .venv/bin/python -m hook_voice pre-tool-monitor <<< '{}'
ls /tmp/tts-monitor-manual-test
```

예상: 파일 존재 확인 (`/tmp/tts-monitor-manual-test`)

```bash
rm /tmp/tts-monitor-manual-test
```

- [ ] **Step 4: 전체 테스트 통과 확인**

```bash
.venv/bin/pytest tests/ -v
```

예상: 전체 passed

- [ ] **Step 5: 커밋**

```bash
git add hooks/pre-tool-monitor.sh .claude/settings.json
git commit -m "feat: Monitor PreToolUse hook 스크립트 및 settings.json 등록"
```
