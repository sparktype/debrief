# tests/test_hook_handlers.py
import json
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from hook_voice.config import Config
from hook_voice.hook_handlers import (
    classify_pre_tool_bash,
    classify_post_tool_bash,
    handle_pre_tool_bash,
    handle_post_tool_bash,
    handle_notification,
    handle_hook,
)

_CFG = Config()

# ── 순수 함수 테스트 ──────────────────────────────────────────

def test_classify_pre_destructive():
    assert classify_pre_tool_bash("rm -rf /tmp/foo") == "주의: 되돌릴 수 없는 작업입니다."

def test_classify_pre_build():
    assert classify_pre_tool_bash("npm run build") == "빌드를 시작합니다."

def test_classify_pre_test():
    assert classify_pre_tool_bash("pytest tests/") == "테스트를 실행합니다."

def test_classify_pre_install():
    assert classify_pre_tool_bash("pip install httpx") == "패키지를 설치합니다."

def test_classify_pre_other():
    assert classify_pre_tool_bash("ls -la") is None

def test_classify_post_build_success():
    assert classify_post_tool_bash("npm run build", "", 0) == "빌드 완료."

def test_classify_post_build_failure():
    assert classify_post_tool_bash("tsc", "", 1) == "빌드 실패. 에러를 확인하세요."

def test_classify_post_test_passed():
    result = classify_post_tool_bash("pytest", "5 passed in 1.2s", 0)
    assert result == "전체 5개 통과."

def test_classify_post_test_failed():
    result = classify_post_tool_bash("pytest", "2 failed, 3 passed", 1)
    assert result is not None
    assert "2개 실패" in result
    assert "3개 통과" in result

def test_classify_post_other():
    assert classify_post_tool_bash("ls", "", 0) is None

# ── 비동기 핸들러 테스트 ─────────────────────────────────────

async def test_handle_pre_tool_bash_speaks():
    raw = json.dumps({"tool_input": {"command": "npm run build"}})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_pre_tool_bash(raw, _CFG)
        mock.assert_called_once()
        assert "빌드" in mock.call_args[0][0]

async def test_handle_pre_tool_bash_silent_for_unknown():
    raw = json.dumps({"tool_input": {"command": "ls -la"}})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_pre_tool_bash(raw, _CFG)
        mock.assert_not_called()

async def test_handle_post_tool_bash_speaks_on_test_pass():
    raw = json.dumps({
        "tool_input": {"command": "pytest"},
        "tool_response": {"output": "3 passed", "exit_code": 0},
    })
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_post_tool_bash(raw, _CFG)
        mock.assert_called_once()

async def test_handle_notification_speaks():
    raw = json.dumps({"message": "Claude가 응답했습니다"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_notification(raw, _CFG)
        mock.assert_called_once_with("Claude가 응답했습니다", _CFG.voice, _CFG.tts_speed,
                                     edge_timeout=_CFG.edge_timeout_ms / 1000)

async def test_handle_notification_uses_title_as_fallback():
    raw = json.dumps({"title": "알림 제목"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_notification(raw, _CFG)
        mock.assert_called_once_with("알림 제목", _CFG.voice, _CFG.tts_speed,
                                     edge_timeout=_CFG.edge_timeout_ms / 1000)

async def test_handle_hook_skips_short_text():
    raw = json.dumps({"last_assistant_message": "짧음"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_hook(raw, _CFG)
        mock.assert_not_called()
