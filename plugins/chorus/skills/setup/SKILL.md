---
name: chorus-setup
description: Install or repair local Chorus TTS (Chorus.app), MCP speak registration, and host hooks for Claude Code.
---

# chorus-setup

## Claude Code (recommended)

From a Chorus build tree:

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

Then:

1. Confirm `mcpServers.chorus` in `~/.claude/settings.json`.
2. Confirm hooks: `SessionStart`, `UserPromptSubmit`, `SubagentStart`.
3. Restart Claude Code (or reconnect MCP) so `speak` / `mcp__chorus__speak` is available.
4. At turn end, call the speak tool once (skill `chorus-speak`).

Mute, mode, diagnostics, start/stop, and quit are **menu bar only** — there is no user CLI.

## All hosts

```bash
.build/release/chorus install --repair
```

- Codex: MCP in `~/.codex/config.toml`, hooks in `~/.codex/hooks.json` — review `/hooks`.
- Grok: MCP in `~/.grok/config.toml`; refresh tools with `/mcps`.
