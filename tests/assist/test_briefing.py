# tests/assist/test_briefing.py — brief_assistant_response 단위 테스트
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from unittest.mock import AsyncMock, patch, MagicMock

import pytest

from hook_voice.assist.briefing import Briefing, brief_assistant_response


# ── 헬퍼 ─────────────────────────────────────────────────────────────────────

_NORMAL_TEXT = "파일을 수정했습니다. 테스트가 모두 통과됐습니다. " * 4
_CODE_HEAVY = "```python\n" + "x = 1\n" * 40 + "```\n짧은 설명"
_EMPTY = ""


# ── Briefing dataclass ─────────────────────────────────────────────────────────

def test_briefing_dataclass_fields():
    b = Briefing(spoken_text="안녕하세요.", hud_summary="안녕", category="briefing", confidence=0.9)
    assert b.spoken_text == "안녕하세요."
    assert b.hud_summary == "안녕"
    assert b.category == "briefing"
    assert b.confidence == 0.9


# ── LLM 성공 케이스 ────────────────────────────────────────────────────────────

async def test_llm_success_returns_briefing():
    """LLM이 정상 응답하면 category='briefing', confidence=0.9를 반환한다."""
    llm_response = "파일 수정이 완료됐습니다. 테스트 5개 모두 통과했습니다."
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value=llm_response)):
        result = await brief_assistant_response(_NORMAL_TEXT)
    assert result.category == "briefing"
    assert result.confidence == 0.9
    assert result.spoken_text  # 비어있지 않음
    assert "```" not in result.spoken_text


async def test_llm_success_hud_summary_truncated():
    """hud_summary는 60자 이하로 잘린다."""
    llm_response = "A" * 120  # 120자 응답
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value=llm_response)):
        result = await brief_assistant_response(_NORMAL_TEXT)
    assert len(result.hud_summary) <= 60


# ── LLM timeout → extract_summary 폴백 ────────────────────────────────────────

async def test_llm_timeout_falls_back_to_extract_summary():
    """LLM timeout 시 extract_summary()로 폴백하고 category='fallback'을 반환한다."""
    async def _timeout(*args, **kwargs):
        raise asyncio.TimeoutError()

    fallback_text = "요약 폴백 텍스트입니다."
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=_timeout)), \
         patch("hook_voice.assist.briefing.extract_summary", new=AsyncMock(return_value=fallback_text)):
        result = await brief_assistant_response(_NORMAL_TEXT, timeout_ms=100)
    assert result.category == "fallback"
    assert result.confidence == 0.5
    assert result.spoken_text == fallback_text


async def test_llm_timeout_does_not_exceed_configured_ms(monkeypatch):
    """asyncio.wait_for에 올바른 timeout이 전달된다."""
    called_with_timeout: list[float] = []

    original_wait_for = asyncio.wait_for

    async def _mock_wait_for(coro, timeout):
        called_with_timeout.append(timeout)
        raise asyncio.TimeoutError()

    with patch("hook_voice.assist.briefing.asyncio.wait_for", side_effect=_mock_wait_for), \
         patch("hook_voice.assist.briefing.extract_summary", new=AsyncMock(return_value="폴백")):
        await brief_assistant_response(_NORMAL_TEXT, timeout_ms=1500)

    assert called_with_timeout == [1.5]


# ── LLM 실패 → extract_summary 폴백 ──────────────────────────────────────────

async def test_llm_exception_falls_back():
    """LLM이 예외를 발생시키면 extract_summary()로 폴백한다."""
    fallback_text = "예외 폴백 텍스트입니다."
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(side_effect=RuntimeError("오류"))), \
         patch("hook_voice.assist.briefing.extract_summary", new=AsyncMock(return_value=fallback_text)):
        result = await brief_assistant_response(_NORMAL_TEXT)
    assert result.category == "fallback"
    assert result.spoken_text == fallback_text


async def test_llm_empty_response_falls_back():
    """LLM이 빈 문자열을 반환하면 extract_summary()로 폴백한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value="")), \
         patch("hook_voice.assist.briefing.extract_summary", new=AsyncMock(return_value="폴백 텍스트")):
        result = await brief_assistant_response(_NORMAL_TEXT)
    assert result.category == "fallback"


# ── 코드 비중 높은 텍스트 → summarize_with_code_hint ──────────────────────────

async def test_code_heavy_skips_llm():
    """코드 비중이 높은 텍스트는 LLM을 호출하지 않고 summarize_with_code_hint를 사용한다."""
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock()) as mock_llm:
        result = await brief_assistant_response(_CODE_HEAVY)
    mock_llm.assert_not_called()
    assert result.category == "code_heavy"
    assert result.confidence == 1.0


async def test_code_heavy_spoken_text_has_no_code_block():
    """코드 비중 높은 응답의 spoken_text에 코드 블록이 없다."""
    result = await brief_assistant_response(_CODE_HEAVY)
    assert "```" not in result.spoken_text


# ── 빈 텍스트 ─────────────────────────────────────────────────────────────────

async def test_empty_text_returns_empty_briefing():
    """빈 텍스트 입력은 category='empty'를 반환한다."""
    result = await brief_assistant_response(_EMPTY)
    assert result.category == "empty"
    assert result.spoken_text == ""
    assert result.confidence == 0.0


# ── spoken_text에 코드 블록 없음 ───────────────────────────────────────────────

async def test_briefing_spoken_text_never_contains_code_block():
    """LLM 응답에 코드 블록이 포함되어 있어도 spoken_text에는 나타나지 않는다."""
    llm_with_code = "수정 완료됐습니다.\n```python\nprint('hello')\n```\n다음 단계로 진행하세요."
    with patch("hook_voice.assist.briefing.chat_completion", new=AsyncMock(return_value=llm_with_code)):
        result = await brief_assistant_response(_NORMAL_TEXT)
    # sanitize_for_speech가 특수문자를 제거하므로 코드 블록 기호가 없어야 함
    assert "```" not in result.spoken_text


# ── HUD snapshot last_event 저장 확인 ────────────────────────────────────────

async def test_handle_hook_updates_hud_snapshot_last_event(tmp_path):
    """handle_hook() 실행 후 HUD 스냅샷의 last_event.kind == 'briefing'이어야 한다."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.speech.pipeline import SpeechContext
    from hook_voice.hook_handlers import handle_hook

    snapshot_path = tmp_path / "hud.json"
    cfg = Config(auto_speak=True, min_chars=10, speech_retouch=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, llm_timeout_ms=2500)

    raw = _json.dumps({"last_assistant_message": _NORMAL_TEXT})

    briefing_obj = Briefing(
        spoken_text="브리핑 텍스트입니다.",
        hud_summary="브리핑 요약",
        category="briefing",
        confidence=0.9,
    )

    mock_ctx = SpeechContext(text="브리핑 텍스트입니다.", ssml="브리핑 텍스트입니다.")
    mock_pipeline = AsyncMock()
    mock_pipeline.process = AsyncMock(return_value=mock_ctx)

    with patch("hook_voice.hook_handlers.brief_assistant_response", new=AsyncMock(return_value=briefing_obj)), \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()), \
         patch("hook_voice.hook_handlers.get_default_pipeline", return_value=mock_pipeline), \
         patch("hook_voice.hook_handlers._HUD_SNAPSHOT_PATH", snapshot_path), \
         patch("hook_voice.hook_handlers.load_snapshot", return_value={"mode": "normal"}), \
         patch("hook_voice.hook_handlers.save_snapshot") as mock_save:
        await handle_hook(raw, cfg)

    mock_save.assert_called_once()
    saved_snapshot = mock_save.call_args.args[0]
    assert "last_event" in saved_snapshot
    assert saved_snapshot["last_event"]["kind"] == "briefing"
    assert saved_snapshot["last_event"]["summary"] == "브리핑 요약"


async def test_handle_hook_briefing_disabled_uses_extract_summary(tmp_path):
    """assistant_tts.enabled=False면 기존 extract_summary 경로를 사용한다."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook

    cfg = Config(auto_speak=True, min_chars=10)
    cfg.assistant_tts = AssistantTtsConfig(enabled=False)

    raw = _json.dumps({"last_assistant_message": _NORMAL_TEXT})

    with patch("hook_voice.hook_handlers.brief_assistant_response", new=AsyncMock()) as mock_brief, \
         patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="기존 요약")) as mock_extract, \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()), \
         patch("hook_voice.hook_handlers.get_default_pipeline") as mock_pipeline:
        mock_pipeline.return_value.process = AsyncMock(
            return_value=MagicMock(text="기존 요약")
        )
        await handle_hook(raw, cfg)

    mock_brief.assert_not_called()
    mock_extract.assert_called_once()
