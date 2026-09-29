---
name: debrief-install
description: Install or repair the debrief daemon and host MCP registration. Prefer MCP install (Claude: mcp__debrief__install; Grok: debrief__install).
---

# debrief-install

## Preferred — MCP tool

| Host | Tool name |
| --- | --- |
| Claude Code | `mcp__debrief__install` |
| Grok | `debrief__install` (`search_tool` → `use_tool`) |
| Codex | `install` on server `debrief` |

```json
{ "hosts": ["claude"], "repair": true }
```

- `hosts`: optional `claude` / `codex` / `grok` (omit = all)
- `repair`: default `true`

Then refresh: **Claude** restart · **Grok** `/mcps`.

## Shell — first install or timeout

```bash
debrief install --repair
# or --claude / --codex / --grok
```

## After success

- `debrief status` shows the process running
- MCP server `debrief` registered
- Skills: setup, install, speak
- Turn-end speech: skill **debrief-speak** — what changed, then one next action.
