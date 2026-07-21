---
name: chorus-setup
description: Install or repair local Chorus TTS (Chorus.app), MCP speak registration, and host hooks for Claude Code.
---

# chorus-setup

Prefer skill **chorus-install** or MCP tool **`install`** (`mcp__chorus__install`).

## Claude Code

1. Call `install` with `{ "hosts": ["claude"], "repair": true }` when MCP works, **or** shell:

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

2. Restart Claude Code.
3. Confirm tools `speak` / `install` (and `mcp__chorus__*`).
4. Turn-end speech: skill **chorus-speak**.

Mute, mode, diagnostics, start/stop, and quit are **menu bar only**.

## All hosts

```bash
.build/release/chorus install --repair
```
