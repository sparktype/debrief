# StructuredLog JSON Lines 출력 로직 테스트
import json
import os
import pytest
from unittest.mock import patch

from hook_voice.observability.context import HookContext
from hook_voice.observability.structured_log import log_event


@pytest.fixture
def ctx():
    return HookContext(
        session_id="abcdef1234567890", seq=7, correlation_id="abcdef12:0007"
    )


def test_outputs_valid_json(ctx, capsys):
    log_event("hook_start", ctx)
    out = capsys.readouterr().err
    data = json.loads(out)
    assert data["event"] == "hook_start"
    assert data["correlation_id"] == "abcdef12:0007"
    assert data["level"] == "INFO"
    assert "ts" in data


def test_includes_extra_fields(ctx, capsys):
    log_event("tts_completed", ctx, {"latency_ms": 312.5, "text_len": 50})
    data = json.loads(capsys.readouterr().err)
    assert data["latency_ms"] == 312.5
    assert data["text_len"] == 50


def test_level_filter_suppresses_info_when_warning(ctx, capsys):
    with patch.dict(os.environ, {"VOICE_LOG_LEVEL": "WARNING"}):
        log_event("hook_start", ctx, level="INFO")
    assert capsys.readouterr().err == ""


def test_level_filter_passes_warning(ctx, capsys):
    with patch.dict(os.environ, {"VOICE_LOG_LEVEL": "WARNING"}):
        log_event("tts_failed", ctx, level="WARNING")
    data = json.loads(capsys.readouterr().err)
    assert data["level"] == "WARNING"


def test_outputs_to_stderr_not_stdout(ctx, capsys):
    log_event("hook_start", ctx)
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err != ""
