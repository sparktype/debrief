# tests/assist/test_failure_explain.py — explain_command_failure 단위 테스트
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from hook_voice.assist.briefing import explain_command_failure


# ── 성공 exit_code(0) → 빈 문자열, LLM 호출 없음 ─────────────────────────────

async def test_success_exit_code_returns_empty_string():
    """exit_code == 0이면 LLM 호출 없이 빈 문자열을 반환한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock()) as mock_llm:
        result = await explain_command_failure("pytest tests/", "5 passed", 0)
    assert result == ""
    mock_llm.assert_not_called()


# ── 실패 exit_code → LLM 호출, 설명 반환 ─────────────────────────────────────

async def test_failed_exit_code_calls_llm_and_returns_explanation():
    """exit_code != 0이면 LLM을 호출하고 설명 텍스트를 반환한다."""
    llm_response = "pytest 실행 중 ImportError가 발생했습니다. 의존 패키지를 확인하세요."
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value=llm_response)):
        result = await explain_command_failure(
            "pytest tests/",
            "ImportError: No module named 'foo'",
            1,
        )
    assert result == llm_response


async def test_failed_exit_code_nonzero_calls_llm():
    """exit_code=2도 실패로 처리한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value="설명")) as mock_llm:
        result = await explain_command_failure("cargo build", "error[E0308]: mismatched types", 2)
    assert result == "설명"
    mock_llm.assert_called_once()


# ── LLM timeout → 빈 문자열 폴백 ─────────────────────────────────────────────

async def test_llm_timeout_returns_empty_string():
    """LLM timeout 시 빈 문자열을 반환하고 hook을 지연시키지 않는다."""
    async def _timeout(*args, **kwargs):
        raise asyncio.TimeoutError()

    with patch("hook_voice.assist.briefing.asyncio.wait_for", side_effect=_timeout):
        result = await explain_command_failure("npm run build", "error TS2345", 1, timeout_ms=100)
    assert result == ""


async def test_llm_exception_returns_empty_string():
    """LLM이 예외를 발생시키면 빈 문자열을 반환한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=RuntimeError("연결 실패"))):
        result = await explain_command_failure("go build ./...", "connection refused", 1)
    assert result == ""


async def test_llm_empty_response_returns_empty_string():
    """LLM이 빈 응답을 반환하면 빈 문자열을 반환한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value="")):
        result = await explain_command_failure("pytest", "1 failed", 1)
    assert result == ""


# ── 시크릿 패턴 redact 확인 ───────────────────────────────────────────────────

async def test_secret_pattern_is_redacted_before_llm():
    """30자 이상 연속 토큰은 LLM에 전달되기 전 [REDACTED]로 치환된다."""
    captured: list[str] = []

    async def _capture(*args, **kwargs):
        messages = kwargs.get("messages") or (args[0] if args else [])
        for msg in messages:
            captured.append(msg.get("content", ""))
        return "설명"

    secret = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6"  # 32자
    output_with_secret = f"Error: token={secret}\nBuild failed."

    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=_capture)):
        await explain_command_failure("cargo build", output_with_secret, 1)

    full_content = " ".join(captured)
    assert secret not in full_content
    assert "[REDACTED]" in full_content


async def test_short_token_is_not_redacted():
    """29자 이하 토큰은 redact하지 않는다."""
    captured: list[str] = []

    async def _capture(*args, **kwargs):
        messages = kwargs.get("messages") or (args[0] if args else [])
        for msg in messages:
            captured.append(msg.get("content", ""))
        return "설명"

    short_token = "ShortToken123"  # 13자
    output = f"Error: token={short_token}"

    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=_capture)):
        await explain_command_failure("pytest", output, 1)

    full_content = " ".join(captured)
    assert short_token in full_content


# ── 긴 출력 → 마지막 30라인만 LLM에 전달 ─────────────────────────────────────

async def test_long_output_sends_only_last_30_lines():
    """출력이 30줄을 초과하면 마지막 30줄만 LLM에 전달된다."""
    captured: list[str] = []

    async def _capture(*args, **kwargs):
        messages = kwargs.get("messages") or (args[0] if args else [])
        for msg in messages:
            captured.append(msg.get("content", ""))
        return "설명"

    lines = [f"line_{i:03d}" for i in range(60)]
    long_output = "\n".join(lines)

    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=_capture)):
        await explain_command_failure("pytest tests/", long_output, 1)

    full_content = " ".join(captured)
    # 앞쪽 라인(line_000~029)은 포함되지 않아야 한다
    assert "line_000" not in full_content
    assert "line_029" not in full_content
    # 마지막 30라인(line_030~059)은 포함되어야 한다
    assert "line_059" in full_content
    assert "line_030" in full_content


async def test_short_output_sends_all_lines():
    """출력이 30줄 이하면 전체를 LLM에 전달한다."""
    captured: list[str] = []

    async def _capture(*args, **kwargs):
        messages = kwargs.get("messages") or (args[0] if args else [])
        for msg in messages:
            captured.append(msg.get("content", ""))
        return "설명"

    output = "\n".join([f"line_{i}" for i in range(10)])

    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=_capture)):
        await explain_command_failure("pytest", output, 1)

    full_content = " ".join(captured)
    assert "line_0" in full_content
    assert "line_9" in full_content
