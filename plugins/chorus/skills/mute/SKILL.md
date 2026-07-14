---
name: chorus-mute
description: Use when automatic Chorus speech should be paused globally, for the current session, for 30 minutes, or restored.
---

# Chorus Mute

Accept one scope: `global`, `session`, `30m`, or `off`. If absent, show current mute state and ask for one scope.

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime mute <scope>`. Report the effective scope and expiry time. Muting never changes the privacy preset, usage tracking, external LLM consent, or listen-mode microphone permission.

Use `off` to restore speech. Do not interpret mute as uninstall or stop the daemon, because hooks and diagnostics must remain available.
