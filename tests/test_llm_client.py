# tests/test_llm_client.py
import logging
import os
import pytest
import httpx
from unittest.mock import AsyncMock, patch, MagicMock
from hook_voice.llm_client import chat_completion, DEFAULT_MODEL

async def test_chat_completion_returns_content():
    response_json = {
        "choices": [{"message": {"content": "요약 결과"}}]
    }
    with patch.dict(os.environ, {"HUB_API_KEY": "test-key", "HUB_BASE_URL": "http://test"}):
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
    with patch.dict(os.environ, {"HUB_API_KEY": "test-key", "HUB_BASE_URL": "http://test"}):
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


async def test_chat_completion_logs_http_status_error(caplog):
    with patch.dict(os.environ, {"HUB_API_KEY": "test-key", "HUB_BASE_URL": "http://test"}):
        with patch("hook_voice.llm_client.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
            response = MagicMock()
            response.status_code = 500
            error = httpx.HTTPStatusError("boom", request=MagicMock(), response=response)
            mock_client.post = AsyncMock(side_effect=error)

            with caplog.at_level(logging.WARNING, logger="hook_voice.llm_client"):
                result = await chat_completion([{"role": "user", "content": "ping"}])

    assert result == ""
    assert "HTTP error" in caplog.text


import time as _time
from hook_voice.observability.circuit_breaker import _breakers, CBState, CircuitBreaker, CircuitBreakerConfig


@pytest.fixture(autouse=True)
def reset_llm_cb():
    yield
    if "llm_api" in _breakers:
        _breakers["llm_api"].reset()
    _breakers.clear()


@pytest.mark.asyncio
async def test_chat_completion_cb_opens_after_failures(monkeypatch):
    """LLM API가 3회 연속 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice import llm_client as _lc

    _breakers["llm_api"] = CircuitBreaker("llm_api", CircuitBreakerConfig(failure_threshold=3))

    async def fail(*args, **kwargs):
        raise Exception("LLM down")

    monkeypatch.setattr(_lc, "_do_chat_completion", fail)
    monkeypatch.setenv("HUB_API_KEY", "testkey")

    for _ in range(3):
        result = await _lc.chat_completion([{"role": "user", "content": "hi"}])
        assert result == ""

    assert _breakers["llm_api"].state == CBState.OPEN


@pytest.mark.asyncio
async def test_chat_completion_cb_open_returns_empty_without_call(monkeypatch):
    """CB OPEN 상태에서 _do_chat_completion을 호출하지 않고 빈 문자열을 반환한다."""
    from hook_voice import llm_client as _lc

    cb = CircuitBreaker("llm_api", CircuitBreakerConfig(failure_threshold=3, recovery_timeout=60.0))
    cb._state = CBState.OPEN
    cb._opened_at = _time.time()
    _breakers["llm_api"] = cb

    called = []

    async def should_not_call(*args, **kwargs):
        called.append(True)
        return "should_not_reach"

    monkeypatch.setattr(_lc, "_do_chat_completion", should_not_call)
    monkeypatch.setenv("HUB_API_KEY", "testkey")

    result = await _lc.chat_completion([{"role": "user", "content": "hi"}])
    assert result == ""
    assert called == []
