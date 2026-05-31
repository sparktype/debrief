# HookContext 생성 및 seq 증가 로직 테스트
import os
import pytest
from unittest.mock import patch

from hook_voice.observability.context import get_or_create_context


@pytest.fixture(autouse=True)
def isolate_seq_file(tmp_path):
    seq_file = tmp_path / "hook_seq.txt"
    with patch("hook_voice.observability.context._SEQ_FILE", seq_file):
        yield seq_file


def test_correlation_id_format():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "abcdef1234567890"}):
        ctx = get_or_create_context()
    assert ctx.correlation_id == "abcdef12:0001"


def test_seq_increments_across_calls():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "abcdef1234567890"}):
        ctx1 = get_or_create_context()
        ctx2 = get_or_create_context()
    assert ctx2.seq == ctx1.seq + 1
    assert ctx2.correlation_id == "abcdef12:0002"


def test_no_session_id_uses_unknown():
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
    with patch.dict(os.environ, env, clear=True):
        ctx = get_or_create_context()
    assert ctx.session_id == "00000000"
    assert ctx.correlation_id.startswith("00000000:")


def test_seq_resets_on_new_session():
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "aaaaaaaaaaaaaaaa"}):
        ctx1 = get_or_create_context()
    with patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "bbbbbbbbbbbbbbbb"}):
        ctx2 = get_or_create_context()
    assert ctx2.seq == 1
