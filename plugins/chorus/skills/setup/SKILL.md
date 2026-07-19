---
name: chorus-setup
description: Install or repair local Chorus TTS (Chorus.app), MCP speak registration, and host hooks.
---

# chorus-setup

Run the Chorus build binary with `install --repair` if the app is missing or broken.
Mute, mode, start/stop, and quit are controlled only from the Chorus menu bar — there is no user CLI.
Speech uses the local MCP tool `speak` on server `chorus` (Grok: `chorus__speak`); hosts register it via install.
For Codex, MCP lives in `~/.codex/config.toml` and hooks in `~/.codex/hooks.json` — remind the user to review hooks in `/hooks`.
For Grok, MCP lives in `~/.grok/config.toml`; refresh tools with `/mcps` after install.
