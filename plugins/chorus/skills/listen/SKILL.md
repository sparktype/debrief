---
name: chorus-listen
description: Use when toggling speech input, checking microphone state, or diagnosing disabled STT, permission, model, or daemon errors.
---

# Chorus Listen

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime listen` and report the resulting `listening`, `stopped`, or `disabled` state.

If disabled, distinguish the recovery:

- daemon unavailable: `chorus-runtime start`
- STT not configured: rerun `/chorus:setup`
- microphone denied: enable microphone access for the active coding-agent app in macOS Settings
- optional model/dependency missing: show the exact installer diagnostic

Never enable external LLM features or usage tracking while enabling speech input.
