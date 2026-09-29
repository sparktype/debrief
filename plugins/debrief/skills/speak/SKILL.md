---
name: debrief-speak
description: Turn-end spoken briefing via MCP speak (Claude: mcp__debrief__speak; Grok: debrief__speak). Use when a user-visible turn ends.
---

# debrief speak

At the end of each user-visible turn, call speak **once**. Two short sentences in the user's language: **what changed**, then the one **next action** or wait. The agent writes the line. **Silence only** if nothing new and no next action.

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__debrief__speak` |
| Grok | `debrief__speak` |
| Codex | `speak` |

## Shape (`lane=companion`, voice **F1**)

Speed ~0.93, volume ~0.85. No file lists, checklists, or chat paste.

## Args

| Field | Required | Notes |
| --- | --- | --- |
| text | yes | ≤ 800 chars. Sentence one: what changed. Sentence two: next action. |
| voice | yes | F1…M5 |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 |
| priority | no | main / subagent |
| lane | no | companion (default) / work |
| emotion | no | neutral, warm, focused, concerned, relieved, tired |

Subagents **do not brief** the user. If they speak: `priority=subagent`, `lane=work`, one fact.

Menu: mute · mode · **도우미 음성** · 진단.
