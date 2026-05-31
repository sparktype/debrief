# asyncio 비동기 Circuit Breaker — CLOSED/OPEN/HALF_OPEN 상태 머신
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

_log = logging.getLogger(__name__)


class CBState(str, Enum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


@dataclass
class CircuitBreakerConfig:
    failure_threshold: int = 3
    recovery_timeout: float = 30.0
    half_open_max_calls: int = 1


class CircuitBreaker:
    """asyncio 비동기 Circuit Breaker."""

    def __init__(self, name: str, config: CircuitBreakerConfig | None = None) -> None:
        self.name = name
        self._cfg = config or CircuitBreakerConfig()
        self._state = CBState.CLOSED
        self._failure_count = 0
        self._opened_at: float = 0.0
        self._half_open_calls = 0
        self._lock = asyncio.Lock()

    @property
    def state(self) -> CBState:
        return self._state

    async def call(
        self, fn: Callable[..., Any], *args: Any, fallback: Any = None, **kwargs: Any
    ) -> Any:
        """fn 실행. OPEN이면 fallback 반환. 실패 시 상태 업데이트 후 예외 전파."""
        async with self._lock:
            if self._state == CBState.OPEN:
                if time.time() - self._opened_at >= self._cfg.recovery_timeout:
                    self._state = CBState.HALF_OPEN
                    self._half_open_calls = 0
                    _log.info("[CB:%s] OPEN → HALF_OPEN", self.name)
                else:
                    _log.debug("[CB:%s] fast-fail (OPEN)", self.name)
                    return fallback() if callable(fallback) else fallback

            if self._state == CBState.HALF_OPEN:
                if self._half_open_calls >= self._cfg.half_open_max_calls:
                    return fallback() if callable(fallback) else fallback
                self._half_open_calls += 1

        try:
            result = await fn(*args, **kwargs)
        except Exception:
            async with self._lock:
                self._failure_count += 1
                if self._state == CBState.HALF_OPEN:
                    self._state = CBState.OPEN
                    self._opened_at = time.time()
                    _log.warning("[CB:%s] HALF_OPEN → OPEN (재시도 실패)", self.name)
                elif self._failure_count >= self._cfg.failure_threshold:
                    self._state = CBState.OPEN
                    self._opened_at = time.time()
                    _log.warning(
                        "[CB:%s] CLOSED → OPEN (연속 실패 %d회)", self.name, self._failure_count
                    )
            raise

        async with self._lock:
            if self._state == CBState.HALF_OPEN:
                self._state = CBState.CLOSED
                self._failure_count = 0
                _log.info("[CB:%s] HALF_OPEN → CLOSED (복구)", self.name)
            elif self._state == CBState.CLOSED:
                self._failure_count = 0
        return result

    def reset(self) -> None:
        self._state = CBState.CLOSED
        self._failure_count = 0
        self._opened_at = 0.0
        self._half_open_calls = 0


_breakers: dict[str, CircuitBreaker] = {}


def get_circuit_breaker(
    name: str, config: CircuitBreakerConfig | None = None
) -> CircuitBreaker:
    if name not in _breakers:
        _breakers[name] = CircuitBreaker(name, config)
    return _breakers[name]
