# Circuit Breaker 상태 머신 단위 테스트
import asyncio
import pytest
from unittest.mock import AsyncMock

from hook_voice.observability.circuit_breaker import (
    CircuitBreaker, CircuitBreakerConfig, CBState, get_circuit_breaker, _breakers,
)


@pytest.fixture(autouse=True)
def clear_breakers():
    _breakers.clear()
    yield
    _breakers.clear()


@pytest.fixture
def cb():
    return CircuitBreaker("test", CircuitBreakerConfig(failure_threshold=2, recovery_timeout=0.05))


@pytest.mark.asyncio
async def test_closed_success_returns_result(cb):
    result = await cb.call(AsyncMock(return_value="ok"))
    assert result == "ok"
    assert cb.state == CBState.CLOSED


@pytest.mark.asyncio
async def test_open_after_threshold(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    assert cb.state == CBState.OPEN


@pytest.mark.asyncio
async def test_open_fast_fail_returns_fallback(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    result = await cb.call(AsyncMock(return_value="ok"), fallback="default")
    assert result == "default"


@pytest.mark.asyncio
async def test_open_fast_fail_does_not_call_fn(cb):
    fail_fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fail_fn)
    probe = AsyncMock(return_value="ok")
    await cb.call(probe, fallback=None)
    probe.assert_not_called()


@pytest.mark.asyncio
async def test_half_open_after_recovery_timeout(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    await asyncio.sleep(0.1)
    result = await cb.call(AsyncMock(return_value="ok"))
    assert result == "ok"
    assert cb.state == CBState.CLOSED


@pytest.mark.asyncio
async def test_half_open_failure_goes_back_to_open(cb):
    fn = AsyncMock(side_effect=ValueError("fail"))
    for _ in range(2):
        with pytest.raises(ValueError):
            await cb.call(fn)
    await asyncio.sleep(0.1)
    with pytest.raises(ValueError):
        await cb.call(AsyncMock(side_effect=ValueError("still failing")))
    assert cb.state == CBState.OPEN


@pytest.mark.asyncio
async def test_success_resets_failure_count(cb):
    fn_fail = AsyncMock(side_effect=ValueError("fail"))
    with pytest.raises(ValueError):
        await cb.call(fn_fail)
    assert cb.state == CBState.CLOSED
    await cb.call(AsyncMock(return_value="ok"))
    with pytest.raises(ValueError):
        await cb.call(fn_fail)
    assert cb.state == CBState.CLOSED


def test_get_circuit_breaker_singleton():
    a = get_circuit_breaker("edge_tts")
    b = get_circuit_breaker("edge_tts")
    assert a is b


def test_get_circuit_breaker_different_names():
    a = get_circuit_breaker("edge_tts")
    b = get_circuit_breaker("supertonic")
    assert a is not b


def test_reset():
    cb = CircuitBreaker("r", CircuitBreakerConfig(failure_threshold=1))
    cb._state = CBState.OPEN
    cb.reset()
    assert cb.state == CBState.CLOSED
