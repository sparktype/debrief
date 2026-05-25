# tests/test_llm_client.py
import logging
import pytest
import httpx
from unittest.mock import AsyncMock, patch, MagicMock
from hook_voice.llm_client import chat_completion, DEFAULT_MODEL

async def test_chat_completion_returns_content():
    response_json = {
        "choices": [{"message": {"content": "요약 결과"}}]
    }
    with patch("hook_voice.llm_client.httpx.AsyncClient") as mock_cls:
        mock_client = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_resp = MagicMock()
        mock_resp.json.return_value = response_json
        mock_resp.raise_for_status = MagicMock()
        mock_client.post = AsyncMock(return_value=mock_resp)

        result = await chat_completion(
            messages=[{"role": "user", "content": "test"}],
            model=DEFAULT_MODEL,
        )
        assert result == "요약 결과"

async def test_chat_completion_returns_empty_on_error():
    with patch("hook_voice.llm_client.httpx.AsyncClient") as mock_cls:
        mock_client = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_client.post = AsyncMock(side_effect=httpx.ConnectError("connection refused"))

        result = await chat_completion(
            messages=[{"role": "user", "content": "test"}],
        )
        assert result == ""


async def test_chat_completion_warns_on_missing_api_key(caplog):
    """HUB_API_KEY 미설정 시 warning 로그 후 빈 문자열 반환."""
    with pytest.MonkeyPatch().context() as m:
        m.delenv("HUB_API_KEY", raising=False)
        with caplog.at_level(logging.WARNING, logger="hook_voice.llm_client"):
            result = await chat_completion([{"role": "user", "content": "ping"}])
    assert result == ""
    assert "HUB_API_KEY" in caplog.text
