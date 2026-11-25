---
name: debrief-speak
description: 'Turn-end spoken briefing via MCP speak (Claude: mcp__debrief__speak; Codex: speak on server debrief; Grok: debrief__speak). Use when a user-visible turn ends.'
---

# debrief speak

| Host | Tool |
| --- | --- |
| Claude Code | `mcp__debrief__speak` |
| Codex | `speak` on server `debrief` |
| Grok | `debrief__speak` (`search_tool` / `use_tool`) |

At the end of each user-visible turn, call speak **once**. Two short sentences in the user's language: **what changed**, then the one **next action** or wait. The agent writes the line. **Silence only** if nothing new and no next action. No file lists, checklists, or chat paste. No HTML/JSON speech in the chat body.

**Code ownership:** after writing, changing, or analyzing code, the next action is the one thing the user must verify themselves (a behavior change, a deletion, a security or data path, an assumption you made, how to check or undo). Skip it for trivial changes.

| Field | Required | Notes |
|-------|----------|--------|
| text | yes | ≤ 800 chars |
| voice | yes | F1…M5. On `lane=companion` the server uses the user's `companionVoice` if set, else one rotating voice per `session`. Work lane uses this value |
| speed / volume | yes | ~0.93 (0.7–2.0) / ~0.85 (0.0–1.0) |
| session | no | Host session id from the hook; keeps the companion voice |
| lane | no | `companion` (default) / `work` (facts only, prefer `neutral`) |
| priority | no | `main` / `subagent` |
| emotion | no | `neutral`, `warm` (long work done), `focused` (mid-task), `concerned` (blocked or failing), `relieved` (a blocker clears), `tired` (rarely). Pauses and a soft cue; speed never changes |
| intent | no | `decision`: the user must decide or approve before work continues. Plays through quiet/night/companion-off with a chime; mute still silences it. Main only |

Modes: focus = one sentence, quiet = one short sentence or silence, night = only `intent=decision`, muted = do not call speak. Claude/Codex hooks append the current mode; Grok gets it from the speak reply (`mode`, `muted`, `reason`) — follow it next turn.

Subagents **do not brief** the user, but speak once when their work is done: `priority=subagent`, `lane=work`, one fact.

Controls: `debrief mute`, `debrief mode`, `debrief companion`, `debrief skip [--all]`, `debrief replay [n]`, `debrief doctor`. Binary: `debrief`.