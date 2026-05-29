# hook_voice/event/router.py — 소스·이벤트 타입 기반 핸들러 라우터
from __future__ import annotations

import logging
from typing import Awaitable, Callable

from .canonical import CanonicalEvent

_log = logging.getLogger(__name__)

Handler = Callable[[CanonicalEvent], Awaitable[None]]


class EventRouter:
    """(source, source_event_type) 쌍을 핸들러 함수로 매핑.

    등록 순서로 첫 번째 매칭 핸들러를 실행한다.
    source 또는 source_event_type에 빈 문자열("")을 쓰면 와일드카드로 동작한다.
    """

    def __init__(self) -> None:
        self._routes: list[tuple[str, str, Handler]] = []
        self._fallback: Handler | None = None

    def register(self, source: str, event_type: str, handler: Handler) -> None:
        self._routes.append((source, event_type, handler))

    def set_fallback(self, handler: Handler) -> None:
        self._fallback = handler

    async def dispatch(self, event: CanonicalEvent) -> bool:
        """매칭 핸들러 실행. 핸들러 발견 시 True, 폴백도 없으면 False."""
        for src, etype, handler in self._routes:
            src_match = src == "" or src == event.source
            type_match = etype == "" or etype == event.source_event_type
            if src_match and type_match:
                try:
                    await handler(event)
                except Exception as e:
                    _log.error(
                        "[Router] 핸들러 오류 source=%s type=%s: %s",
                        event.source, event.source_event_type, e,
                    )
                return True

        if self._fallback:
            try:
                await self._fallback(event)
            except Exception as e:
                _log.error("[Router] 폴백 핸들러 오류: %s", e)
            return True

        _log.debug(
            "[Router] 미등록 이벤트 — source=%s type=%s",
            event.source, event.source_event_type,
        )
        return False
