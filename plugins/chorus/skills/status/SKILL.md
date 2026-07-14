---
name: chorus-status
description: Use when checking Chorus setup, privacy, daemon, hook delivery, queue, mute state, paths, or the latest error.
---

# Chorus Status

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime status` and present its result without hiding failed or unknown fields.

Lead with configured preset, automatic speech, external LLM transmission, and usage tracking. Then report runtime release, daemon health, last Claude and Codex hook delivery, queue depth, mute state, and last error.

If Codex delivery has never succeeded, include the emitted `/hooks` review guidance. Status is read-only: do not start the daemon, change privacy, trust hooks, or play audio.
