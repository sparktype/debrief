---
name: chorus-speak
description: Speak a short finish summary through local Chorus TTS via MCP speak (Claude: mcp__chorus__speak; Grok: chorus__speak).
---

# Chorus speak

When you finish a turn that deserves a spoken summary, call the Chorus MCP tool **once**:

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__chorus__speak` |
| Grok | `chorus__speak` (`search_tool` / `use_tool`) |
| Codex | `speak` on server `chorus` |

| Field | Required | Notes |
| --- | --- | --- |
| text | yes | ≤ 800 chars |
| voice | yes | F1…F5, M1…M5 (default main F1) |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 (typical 0.85) |
| priority | no | `main` (default) or `subagent` |

- Do **not** put HTML comments or JSON speech metadata in the message body
- Omitting the tool is silence
- Mute/mode/diagnostics: menu bar only
- Repair wiring: skill **chorus-install** / MCP **install**
