# hook_voice/__main__.py
# python -m hook_voice <subcommand> 진입점
import asyncio
import sys

from .config import load_config, _find_default_config, _VOICE_JSON
from .hook_handlers import (
    handle_hook,
    handle_notification,
    handle_subagent_stop,
    handle_hook_suggest,
    handle_pre_tool_bash,
    handle_post_tool_bash,
    handle_history,
    handle_health,
    handle_config,
    handle_control,
    handle_grafana,
    handle_pre_tool_monitor,
    handle_voice_test,
    handle_doctor,
    handle_suggest_config,
    handle_privacy,
)


async def _read_stdin() -> str:
    if sys.stdin.isatty():
        return ""
    loop = asyncio.get_running_loop()
    data = await loop.run_in_executor(None, sys.stdin.buffer.read)
    return data.decode("utf-8").strip()


async def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python -m hook_voice <subcommand>", file=sys.stderr)
        sys.exit(1)

    subcommand = sys.argv[1]
    config = load_config()
    raw = await _read_stdin()

    if subcommand == "hook":
        await handle_hook(raw, config)
    elif subcommand == "notification":
        await handle_notification(raw, config)
    elif subcommand == "subagent-stop":
        agent_type = sys.argv[2] if len(sys.argv) > 2 else ""
        await handle_subagent_stop(raw, agent_type, config)
    elif subcommand == "hook-suggest":
        await handle_hook_suggest(raw, config)
    elif subcommand == "pre-tool-bash":
        await handle_pre_tool_bash(raw, config)
    elif subcommand == "post-tool-bash":
        await handle_post_tool_bash(raw, config)
    elif subcommand == "history":
        await handle_history(sys.argv[2:], config)
    elif subcommand == "health":
        await handle_health()
    elif subcommand == "config":
        await handle_config(sys.argv[2:], _find_default_config() or _VOICE_JSON)
    elif subcommand == "control":
        action = sys.argv[2] if len(sys.argv) > 2 else ""
        await handle_control(action)
    elif subcommand == "pre-tool-monitor":
        await handle_pre_tool_monitor(raw)
    elif subcommand == "grafana":
        await handle_grafana(sys.argv[2:], _find_default_config() or _VOICE_JSON)
    elif subcommand == "voice":
        sub = sys.argv[2] if len(sys.argv) > 2 else ""
        if sub == "test":
            await handle_voice_test(sys.argv[3:], config)
        else:
            print("Usage: python -m hook_voice voice test [voice_id] [text]", file=sys.stderr)
    elif subcommand == "doctor":
        await handle_doctor(config)
    elif subcommand == "suggest-config":
        await handle_suggest_config(config)
    elif subcommand == "privacy":
        await handle_privacy(sys.argv[2:], config)
    else:
        print(f"Unknown subcommand: {subcommand}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
