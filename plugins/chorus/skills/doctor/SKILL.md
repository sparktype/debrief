---
name: chorus-doctor
description: Use when Chorus is silent, hooks are not firing, setup fails, the daemon is unhealthy, or an exact recovery command is needed.
---

# Chorus Doctor

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime doctor`.

Report every check as pass or fail and preserve the exact recovery command for each failure. Diagnostics cover platform, runtime, configuration, LaunchAgent/daemon, hook delivery, duplicate legacy services, and data-directory access.

Doctor must not send source text to an external LLM. Do not play audio unless the user explicitly asks for an audible smoke test. In Codex, a missing delivery record requires `/hooks` review before reinstalling anything.
