---
name: chorus-speak
description: Reflective companion TTS via MCP speak (Claude: mcp__chorus__speak; Grok: chorus__speak). Silence OK; optional lane/emotion.
---

# Chorus speak

Prefer **one short companion line** when speech helps. **Silence is correct** for thrash, repeated status, or on-screen lists.

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__chorus__speak` |
| Grok | `chorus__speak` |
| Codex | `speak` |

## Companion (`lane=companion`, default)

Observe + meaning + one next step. Prefer **F1**, speed ~0.93, volume ~0.85.

Avoid file lists, checklists, chat paste, hype.

## Args

| Field | Required | Notes |
| --- | --- | --- |
| text | yes | ≤ 800 chars |
| voice | yes | F1…M5 |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 |
| priority | no | main / subagent |
| lane | no | companion (default) / work |
| emotion | no | neutral, warm, focused, concerned, relieved, tired |

Menu: mute · mode · **도우미 음성** · 진단.
