from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Mapping

HookSource = Literal["claude", "codex", "opencode", "unknown"]


@dataclass(frozen=True)
class HookEvent:
    source: HookSource
    event_name: str
    session_id: str
    cwd: Path | None
    transcript_path: Path | None
    turn_id: str | None
    agent_id: str | None
    agent_type: str | None
    assistant_message: str | None
    tool_name: str | None
    tool_input: Mapping[str, object]
    tool_response: Mapping[str, object]
    raw: Mapping[str, object]


def _text(payload: Mapping[str, object], *keys: str) -> str | None:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _mapping(payload: Mapping[str, object], *keys: str) -> Mapping[str, object]:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, Mapping):
            return dict(value)
    return {}


def _path(value: str | None) -> Path | None:
    return Path(value).expanduser() if value else None


def _claude_transcript_fallback(env: Mapping[str, str], session_id: str, cwd: Path | None) -> Path | None:
    project = env.get("CLAUDE_PROJECT_DIR") or (str(cwd) if cwd else "")
    home = env.get("HOME", "")
    if not session_id or not project or not home:
        return None
    return Path(home) / ".claude/projects" / project.replace("/", "-") / f"{session_id}.jsonl"


def adapt_hook_payload(
    payload: Mapping[str, object],
    *,
    source: str,
    event_name: str,
    env: Mapping[str, str] | None = None,
) -> HookEvent:
    values = os.environ if env is None else env
    normalized_source: HookSource = source if source in {"claude", "codex", "opencode"} else "unknown"  # type: ignore[assignment]
    session_id = _text(payload, "session_id", "sessionId", "conversation_id", "conversationId") or values.get("CLAUDE_CODE_SESSION_ID", "")
    cwd = _path(_text(payload, "cwd", "working_directory", "workingDirectory") or values.get("CLAUDE_PROJECT_DIR"))
    transcript = _path(_text(payload, "transcript_path", "transcriptPath"))
    if transcript is None and normalized_source == "claude":
        transcript = _claude_transcript_fallback(values, session_id, cwd)
    return HookEvent(
        source=normalized_source,
        event_name=event_name,
        session_id=session_id,
        cwd=cwd,
        transcript_path=transcript,
        turn_id=_text(payload, "turn_id", "turnId"),
        agent_id=_text(payload, "agent_id", "agentId"),
        agent_type=_text(payload, "agent_type", "agentType"),
        assistant_message=_text(payload, "last_assistant_message", "assistant_message", "assistantMessage", "message"),
        tool_name=_text(payload, "tool_name", "toolName"),
        tool_input=_mapping(payload, "tool_input", "toolInput", "input"),
        tool_response=_mapping(payload, "tool_response", "toolResponse", "response", "result"),
        raw=dict(payload),
    )
