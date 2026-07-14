---
name: chorus-mode
description: Use when changing Chorus speaking frequency, pacing, or verbosity with a named normal, focus, quiet, verbose, or night preset.
---

# Chorus Mode

Accept exactly one mode: `normal`, `focus`, `quiet`, `verbose`, or `night`. If absent, show the current mode and the five valid names.

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime mode <name>` and report the resulting minimum response length, speed, and bridge behavior.

Modes shape speech presentation only. They must not enable tracking, external LLM transmission, microphone input, or automatic speech when the user is globally muted.
