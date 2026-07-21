---
name: chorus-speak
description: Speak a short finish summary through local Chorus TTS via MCP tool speak (Claude: mcp__chorus__speak). Use at end of a turn when a spoken one- or two-sentence summary helps.
---

# Chorus speak

When you finish a turn that deserves a spoken summary, call the Chorus MCP tool **once**:

- Claude Code: server `chorus`, tool `speak` (often listed as `mcp__chorus__speak`)
- Codex: server `chorus`, tool `speak`
- Required arguments: `text`, `voice`, `speed`, `volume`
- Optional: `priority` = `main` (default) or `subagent` (background agents; suppressed in focus/quiet/night)
- Default main voice: `F1`, speed near `0.93`, volume near `0.85`
- Keep `text` ≤ 800 characters
- Do **not** put HTML comments or JSON speech metadata in the assistant message body
- Omitting the tool is silence
- Mute/mode/diagnostics are menu bar only

Prefer `chorus install --claude` (or full `chorus install`) so MCP and start-family hooks point at the absolute `Chorus.app` binary.
