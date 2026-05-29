# hook_voice/adapters/coding_agent.py — Claude Code hook 이벤트 → CanonicalEvent 변환
from __future__ import annotations

import json
import logging
from pathlib import Path

from ..event.canonical import CanonicalEvent, InterruptPolicy, Severity

_log = logging.getLogger(__name__)

# hook subcommand → (severity, priority_score, interrupt_policy)
_EVENT_PROFILE: dict[str, tuple[Severity, int, InterruptPolicy]] = {
    "stop":              (Severity.INFO,   40, InterruptPolicy.QUEUE),
    "subagent_stop":     (Severity.INFO,   30, InterruptPolicy.QUEUE),
    "pre_tool_bash":     (Severity.LOW,    10, InterruptPolicy.DISCARD),
    "post_tool_bash":    (Severity.LOW,    10, InterruptPolicy.DISCARD),
    "notification":      (Severity.MEDIUM, 50, InterruptPolicy.QUEUE),
    "hook_suggest":      (Severity.LOW,    10, InterruptPolicy.DISCARD),
}


class CodingAgentAdapter:
    """Claude Code hook 이벤트를 CanonicalEvent로 변환하는 어댑터."""

    def source_id(self) -> str:
        return "coding_agent"

    async def to_canonical_event(
        self,
        raw: str,
        event_type: str = "stop",
        agent_type: str = "",
        **kwargs,
    ) -> CanonicalEvent | None:
        severity, priority, policy = _EVENT_PROFILE.get(
            event_type, (Severity.INFO, 20, InterruptPolicy.QUEUE)
        )

        text = ""
        metadata: dict = {}
        try:
            data = json.loads(raw) if raw.strip() else {}
            text = data.get("last_assistant_message", "")
            metadata = {k: v for k, v in data.items() if k != "last_assistant_message"}
        except (json.JSONDecodeError, AttributeError):
            text = raw

        if agent_type:
            metadata["agent_type"] = agent_type

        fingerprint = _fingerprint(event_type, text[:80])
        return CanonicalEvent(
            source=self.source_id(),
            source_event_type=event_type,
            severity=severity,
            priority_score=priority,
            interrupt_policy=policy,
            raw_text=text,
            fingerprint=fingerprint,
            dedupe_key=fingerprint,
            metadata=metadata,
        )

    async def health_check(self) -> bool:
        return True  # 로컬 파이프 — 항상 정상


def _fingerprint(event_type: str, text_prefix: str) -> str:
    import hashlib
    raw = f"{event_type}:{text_prefix}"
    return hashlib.md5(raw.encode()).hexdigest()[:16]
