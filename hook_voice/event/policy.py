# hook_voice/event/policy.py — 이벤트 처리 정책 엔진 (중복 제거·TTL·필터)
from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field

from .canonical import CanonicalEvent


@dataclass(frozen=True)
class PolicyRules:
    """불변 정책 규칙 집합."""
    dedupe_ttl: float = 60.0       # 동일 dedupe_key 재발화 억제 시간(초)
    min_priority: int = 0          # 이 값 미만 priority_score 이벤트 드롭
    max_text_len: int = 2000       # raw_text 최대 길이 — 초과 시 자름


class InMemoryStateStore:
    """asyncio.Lock 기반 원자적 중복 감지 스토어."""

    def __init__(self) -> None:
        self._seen: dict[str, float] = {}  # dedupe_key → 마지막 처리 시각
        self._lock = asyncio.Lock()

    async def check_and_mark_duplicate(self, dedupe_key: str, ttl: float) -> bool:
        """이미 처리된 키면 True(중복), 아니면 False(신규) — 원자적."""
        if not dedupe_key:
            return False
        async with self._lock:
            now = time.time()
            last = self._seen.get(dedupe_key)
            if last is not None and now - last < ttl:
                return True  # 중복
            self._seen[dedupe_key] = now
            return False

    async def purge_expired(self, ttl: float) -> int:
        """만료된 항목 제거. 제거된 수 반환."""
        async with self._lock:
            now = time.time()
            expired = [k for k, t in self._seen.items() if now - t >= ttl]
            for k in expired:
                del self._seen[k]
            return len(expired)


class PolicyDecisionEngine:
    """규칙 + 상태를 결합해 이벤트 통과/드롭 결정."""

    def __init__(self, rules: PolicyRules, state: InMemoryStateStore) -> None:
        self._rules = rules
        self._state = state

    async def should_process(self, event: CanonicalEvent) -> tuple[bool, str]:
        """(통과 여부, 거부 이유). 거부면 False + 사유 문자열."""
        if event.priority_score < self._rules.min_priority:
            return False, f"priority_score {event.priority_score} < min {self._rules.min_priority}"

        if event.is_expired():
            return False, "TTL 만료"

        if event.dedupe_key:
            is_dup = await self._state.check_and_mark_duplicate(
                event.dedupe_key, self._rules.dedupe_ttl
            )
            if is_dup:
                return False, f"중복 이벤트 (dedupe_key={event.dedupe_key})"

        return True, ""

    def truncate_text(self, event: CanonicalEvent) -> CanonicalEvent:
        """raw_text가 max_text_len을 초과하면 자른다."""
        if len(event.raw_text) > self._rules.max_text_len:
            event.raw_text = event.raw_text[: self._rules.max_text_len]
        return event
