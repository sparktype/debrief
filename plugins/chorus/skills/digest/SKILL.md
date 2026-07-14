---
name: chorus-digest
description: Use when reviewing recent Chorus hook events, spoken messages, failures, or delivery history without changing runtime state.
---

# Chorus Digest

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime digest ${COUNT:-10}` and summarize the returned events in chronological order.

Include provider, event kind, whether speech was queued or skipped, and any delivery/runtime error. Do not expose full prompts or assistant source text when the stored record contains only metadata.

Digest is read-only. It never enables usage tracking retroactively and must say when no history exists because tracking is disabled or setup has not completed.
