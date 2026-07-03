# tests/assist/test_recommend.py — recommend_prompt_assist 단위 테스트
from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from unittest.mock import AsyncMock, patch, MagicMock

import pytest

from hook_voice.assist.recommend import (
    Recommendation,
    recommend_prompt_assist,
    _RECOMMEND_COOLDOWN_PATH,
    _load_recommend_cooldowns,
    _save_recommend_cooldowns,
)


# ── 헬퍼 ─────────────────────────────────────────────────────────────────────

_ANALYSIS_PROMPT = "이 코드의 성능 병목 구간을 분석하고 리뷰해 주세요."
_NOISY_PROMPT = "왜 자꾸 실패하지? 또 에러야."
_SETUP_PROMPT = "환경 설정해줘"


def setup_function():
    """각 테스트 전 쿨다운 파일 초기화."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()


def _make_llm_response(mode: str, reason: str = "분석 작업입니다.") -> str:
    return json.dumps({"kind": "mode", "value": mode, "reason": reason})


# ── Recommendation dataclass ──────────────────────────────────────────────────

def test_recommendation_dataclass():
    rec = Recommendation(kind="mode", value="focus", reason="분석 작업입니다.")
    assert rec.kind == "mode"
    assert rec.value == "focus"
    assert rec.reason == "분석 작업입니다."


# ── analysis/review 프롬프트 → focus 추천 ─────────────────────────────────────

async def test_analysis_prompt_returns_focus():
    """분석/리뷰 프롬프트는 focus 모드를 추천한다."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()
    llm_resp = _make_llm_response("focus", "분석 작업으로 판단됩니다.")

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value=llm_resp)):
        rec = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert rec is not None
    assert rec.kind == "mode"
    assert rec.value == "focus"
    assert rec.reason


# ── LLM timeout → None 반환 ───────────────────────────────────────────────────

async def test_llm_timeout_returns_none():
    """LLM timeout 시 None을 반환한다 (fail-open)."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()

    async def _timeout(*args, **kwargs):
        raise asyncio.TimeoutError()

    with patch("hook_voice.assist.recommend.asyncio.wait_for", side_effect=_timeout):
        rec = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
            timeout_ms=100,
        )

    assert rec is None


# ── LLM 예외 → None 반환 ─────────────────────────────────────────────────────

async def test_llm_exception_returns_none():
    """LLM이 예외를 발생시키면 None을 반환한다."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(side_effect=RuntimeError("오류"))):
        rec = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert rec is None


# ── 쿨다운: 300초 내 동일 value 재호출 → None ────────────────────────────────

async def test_cooldown_suppresses_duplicate_within_300s():
    """300초 내 동일 value 재호출 시 None을 반환한다 (파일 기반 쿨다운)."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()
    llm_resp = _make_llm_response("focus", "분석 작업으로 판단됩니다.")

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value=llm_resp)):
        first = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )
        second = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert first is not None
    assert first.value == "focus"
    assert second is None  # 쿨다운으로 억제됨


# ── 쿨다운 만료 → 다시 추천 ──────────────────────────────────────────────────

async def test_cooldown_expired_recommends_again():
    """쿨다운 만료 후에는 다시 추천을 반환한다 (파일 기반 쿨다운)."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()
    llm_resp = _make_llm_response("focus", "분석 작업으로 판단됩니다.")

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value=llm_resp)):
        first = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert first is not None

    # 쿨다운을 만료 상태로 강제 설정 (파일에 과거 시각 기록)
    _save_recommend_cooldowns({"focus": time.time() - 301.0})

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value=llm_resp)):
        second = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert second is not None
    assert second.value == "focus"


# ── LLM 잘못된 JSON → None 반환 ──────────────────────────────────────────────

async def test_invalid_llm_json_returns_none():
    """LLM이 JSON이 아닌 응답을 반환하면 None을 반환한다."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value="잘못된 응답")):
        rec = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert rec is None


# ── 빈 value → None 반환 ─────────────────────────────────────────────────────

async def test_empty_value_returns_none():
    """LLM 응답에 value가 없으면 None을 반환한다."""
    if _RECOMMEND_COOLDOWN_PATH.exists():
        _RECOMMEND_COOLDOWN_PATH.unlink()
    llm_resp = json.dumps({"kind": "mode", "value": "", "reason": "분석"})

    with patch("hook_voice.assist.recommend.chat_completion", new=AsyncMock(return_value=llm_resp)):
        rec = await recommend_prompt_assist(
            prompt=_ANALYSIS_PROMPT,
            transcript_context="",
            stats={},
            model="gemini-3.5-flash",
        )

    assert rec is None


# ── HUD snapshot suggestion 필드 업데이트 확인 ───────────────────────────────

async def test_handle_hook_suggest_updates_hud_snapshot_suggestion(tmp_path):
    """handle_hook_suggest() 실행 후 HUD 스냅샷에 suggestion 필드가 저장된다."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook_suggest

    cfg = Config(auto_speak=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, prompt_advice=True)

    snapshot_path = tmp_path / "hud.json"
    raw = _json.dumps({"prompt": _ANALYSIS_PROMPT})

    rec = Recommendation(kind="mode", value="focus", reason="분석 작업으로 판단됩니다.")

    with patch("hook_voice.hook_handlers.recommend_prompt_assist", new=AsyncMock(return_value=rec)), \
         patch("hook_voice.hook_handlers.recommend_skill", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.read_recent_transcripts", return_value=""), \
         patch("hook_voice.hook_handlers._HUD_SNAPSHOT_PATH", snapshot_path), \
         patch("hook_voice.hook_handlers.load_snapshot", return_value={"mode": "normal"}), \
         patch("hook_voice.hook_handlers.save_snapshot") as mock_save, \
         patch("hook_voice.hook_handlers._load_stats", return_value=[]), \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()):
        await handle_hook_suggest(raw, cfg)

    mock_save.assert_called()
    saved_snapshot = mock_save.call_args.args[0]
    assert "suggestion" in saved_snapshot
    assert saved_snapshot["suggestion"]["kind"] == "mode"
    assert saved_snapshot["suggestion"]["value"] == "focus"
    assert saved_snapshot["suggestion"]["reason"]


# ── prompt_advice=False → recommend_prompt_assist 호출 안 함 ──────────────────

async def test_prompt_advice_false_skips_recommend():
    """prompt_advice=False이면 recommend_prompt_assist를 호출하지 않는다."""
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook_suggest
    import json as _json

    cfg = Config(auto_speak=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, prompt_advice=False)

    raw = _json.dumps({"prompt": _ANALYSIS_PROMPT})

    with patch("hook_voice.hook_handlers.recommend_prompt_assist", new=AsyncMock()) as mock_rec, \
         patch("hook_voice.hook_handlers.recommend_skill", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.read_recent_transcripts", return_value=""), \
         patch("hook_voice.hook_handlers._load_stats", return_value=[]):
        await handle_hook_suggest(raw, cfg)

    mock_rec.assert_not_called()


# ── mode_rec TTS 발화 테스트 ──────────────────────────────────────────────────

async def test_handle_hook_suggest_speaks_mode_recommendation(tmp_path):
    """mode_rec가 있으면 TTS로 추천 내용을 발화한다."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook_suggest

    cfg = Config(auto_speak=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, prompt_advice=True)

    raw = _json.dumps({"prompt": _ANALYSIS_PROMPT})
    rec = Recommendation(kind="mode", value="focus", reason="분석 작업으로 판단됩니다.")

    with patch("hook_voice.hook_handlers.recommend_prompt_assist", new=AsyncMock(return_value=rec)), \
         patch("hook_voice.hook_handlers.recommend_skill", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.read_recent_transcripts", return_value=""), \
         patch("hook_voice.hook_handlers.load_snapshot", return_value={}), \
         patch("hook_voice.hook_handlers.save_snapshot"), \
         patch("hook_voice.hook_handlers._load_stats", return_value=[]), \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()) as mock_speak:
        await handle_hook_suggest(raw, cfg)

    mock_speak.assert_called_once()
    spoken = mock_speak.call_args.args[0]
    assert "focus" in spoken
    assert "추천" in spoken


async def test_handle_hook_suggest_no_tts_when_no_mode_rec(tmp_path):
    """mode_rec가 None이면 TTS를 호출하지 않는다."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook_suggest

    cfg = Config(auto_speak=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, prompt_advice=True)

    raw = _json.dumps({"prompt": _ANALYSIS_PROMPT})

    with patch("hook_voice.hook_handlers.recommend_prompt_assist", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.recommend_skill", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.read_recent_transcripts", return_value=""), \
         patch("hook_voice.hook_handlers._load_stats", return_value=[]), \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock()) as mock_speak:
        await handle_hook_suggest(raw, cfg)

    mock_speak.assert_not_called()


async def test_handle_hook_suggest_tts_fail_open(tmp_path):
    """TTS 발화가 실패해도 hook이 예외 없이 정상 종료된다 (fail-open)."""
    import json as _json
    from hook_voice.config import Config, AssistantTtsConfig
    from hook_voice.hook_handlers import handle_hook_suggest

    cfg = Config(auto_speak=True)
    cfg.assistant_tts = AssistantTtsConfig(enabled=True, prompt_advice=True)

    raw = _json.dumps({"prompt": _ANALYSIS_PROMPT})
    rec = Recommendation(kind="mode", value="quiet", reason="노이즈가 많은 세션입니다.")

    with patch("hook_voice.hook_handlers.recommend_prompt_assist", new=AsyncMock(return_value=rec)), \
         patch("hook_voice.hook_handlers.recommend_skill", new=AsyncMock(return_value=None)), \
         patch("hook_voice.hook_handlers.read_recent_transcripts", return_value=""), \
         patch("hook_voice.hook_handlers.load_snapshot", return_value={}), \
         patch("hook_voice.hook_handlers.save_snapshot"), \
         patch("hook_voice.hook_handlers._load_stats", return_value=[]), \
         patch("hook_voice.hook_handlers.speak_hook_chunked", new=AsyncMock(side_effect=RuntimeError("TTS 오류"))):
        # 예외 없이 종료되어야 함
        await handle_hook_suggest(raw, cfg)
