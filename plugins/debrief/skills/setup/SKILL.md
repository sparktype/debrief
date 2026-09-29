---
name: debrief-setup
description: Guide debrief TTS setup for Claude Code, Codex, and Grok. Prefer debrief-install or MCP install tool.
---

# debrief-setup

Prefer skill **debrief-install** or MCP tool **`install`**:

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__debrief__install` |
| Grok | `debrief__install` (`search_tool` / `use_tool`) |
| Codex | `install` on server `debrief` |

## Claude Code

1. `{ "hosts": ["claude"], "repair": true }` via install tool, **or** shell:

```bash
debrief install --claude --repair
```

2. **Restart Claude Code.**
3. Confirm `mcp__debrief__speak` and `mcp__debrief__install`.
4. Turn-end speech: skill **debrief-speak** — what changed, then one next action.

## Grok

1. `{ "hosts": ["grok"], "repair": true }` via `debrief__install`, **or**:

```bash
debrief install --grok --repair
```

2. Run **`/mcps`**.
3. Turn-end speech: skill **debrief-speak** → `debrief__speak` (what changed, then one next action).

## All hosts

```bash
debrief install --repair
```

Mute, mode, companion, diagnostics, and start/stop: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`, `debrief start`, `debrief stop`.
