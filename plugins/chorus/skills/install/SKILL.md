---
name: chorus-install
description: Install or repair Chorus.app, MCP tools (speak/install), and Claude Code hooks. Prefer MCP tool install (mcp__chorus__install).
---

# chorus-install

## Preferred — MCP tool

When the Chorus MCP server is already available, call **`install`** (Claude: `mcp__chorus__install`):

| Argument | Default | Notes |
|----------|---------|--------|
| `hosts` | all | Array: `claude`, `codex`, `grok` |
| `repair` | `true` | Re-verify model + re-merge owned hooks/MCP |

Claude-only repair:

```json
{ "hosts": ["claude"], "repair": true }
```

Then **restart Claude Code** so `mcp__chorus__speak` / `mcp__chorus__install` refresh.

## Shell — first install or MCP timeout

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

Installed binary:

```bash
'/Applications/Chorus.app/Contents/MacOS/chorus' install --claude --repair
```

## After success

- Menu bar app running (LaunchAgent)
- `~/.claude/settings.json` → `mcpServers.chorus`
- Skills: `chorus-setup`, `chorus-install`, `chorus-speak`
- Use `speak` at turn end (skill `chorus-speak`)
