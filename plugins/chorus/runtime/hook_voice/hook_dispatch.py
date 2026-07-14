from __future__ import annotations

import json

from .config import Config
from .event.hook_event import HookEvent
from .hook_handlers import (
    handle_hook,
    handle_hook_suggest,
    handle_post_tool_bash,
    handle_pre_tool_bash,
    handle_subagent_stop,
)


def _legacy_payload(event: HookEvent) -> str:
    payload = dict(event.raw)
    if event.assistant_message:
        payload.setdefault("last_assistant_message", event.assistant_message)
    if event.tool_name:
        payload.setdefault("tool_name", event.tool_name)
    if event.tool_input:
        payload.setdefault("tool_input", dict(event.tool_input))
    if event.tool_response:
        payload.setdefault("tool_response", dict(event.tool_response))
    return json.dumps(payload, ensure_ascii=False)


async def dispatch_hook_event(event: HookEvent, config: Config) -> None:
    raw = _legacy_payload(event)
    if event.event_name == "Stop":
        await handle_hook(raw, config)
    elif event.event_name == "SubagentStop":
        await handle_subagent_stop(raw, event.agent_type or "", config)
    elif event.event_name == "PreToolUse" and event.tool_name == "Bash":
        await handle_pre_tool_bash(raw, config)
    elif event.event_name == "PostToolUse" and event.tool_name == "Bash":
        await handle_post_tool_bash(raw, config)
    elif event.event_name in {"UserPromptSubmit", "SessionStart"}:
        await handle_hook_suggest(raw, config)
