---
name: chorus-setup
description: Use when Chorus is newly installed, unconfigured, being upgraded, or needs a privacy preset and voice verification.
---

# Chorus Setup

Set up Chorus without silently enabling speech, tracking, or external transmission.

1. Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime status --json`.
2. Explain the presets: `local` keeps summaries and tracking local/off; `standard` may send Stop text for summaries; `detailed` additionally enables failure and prompt assistance plus usage tracking.
3. If the user has not named a preset, ask for exactly one of `local`, `standard`, or `detailed`.
4. State the configured external endpoint before saving `standard` or `detailed`.
5. Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime install`, then `.../chorus-runtime setup <preset>`.
6. In Codex, tell the user to review Chorus in `/hooks`. Finish with `.../chorus-runtime status`.

Do not infer consent from legacy configuration. A legacy-disabled capability stays disabled.
