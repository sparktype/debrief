---
name: chorus-setup
description: Guide Chorus TTS setup for Claude Code, Codex, and Grok. Prefer chorus-install or MCP install tool.
---

# chorus-setup

Prefer skill **chorus-install** or MCP tool **`install`**:

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__chorus__install` |
| Grok | `chorus__install` (`search_tool` / `use_tool`) |
| Codex | `install` on server `chorus` |

## Claude Code

1. `{ "hosts": ["claude"], "repair": true }` via install tool, **or** shell:

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

2. **Restart Claude Code.**
3. Confirm `mcp__chorus__speak` and `mcp__chorus__install`.
4. Turn-end speech: skill **chorus-speak** — what changed, then one next action.

## Grok

1. `{ "hosts": ["grok"], "repair": true }` via `chorus__install`, **or**:

```bash
.build/release/chorus install --grok --repair
```

2. Run **`/mcps`**.
3. Turn-end speech: skill **chorus-speak** → `chorus__speak` (what changed, then one next action).

## All hosts

```bash
.build/release/chorus install --repair
```

Mute, mode, diagnostics, start/stop, and quit are **menu bar only**.
