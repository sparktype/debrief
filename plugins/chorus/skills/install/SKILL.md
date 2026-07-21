---
name: chorus-install
description: Install or repair Chorus.app and host MCP registration. Prefer MCP install (Claude: mcp__chorus__install; Grok: chorus__install).
---

# chorus-install

## Preferred — MCP tool

| Host | Tool name |
|------|-----------|
| Claude Code | `mcp__chorus__install` |
| Grok | `chorus__install` (`search_tool` → `use_tool`) |
| Codex | `install` on server `chorus` |

```json
{ "hosts": ["grok"], "repair": true }
```

- `hosts`: optional `claude` / `codex` / `grok` (omit = all)
- `repair`: default `true`

Then refresh: **Claude** restart · **Grok** `/mcps`.

## Shell — first install or timeout

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --grok --repair
# or --claude / --codex / no flags for all
```

```bash
'/Applications/Chorus.app/Contents/MacOS/chorus' install --grok --repair
```

## After success

- Menu bar Chorus running
- MCP server `chorus` registered
- Skills: setup, install, speak
- Turn-end speech: skill **chorus-speak**
