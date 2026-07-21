# Chorus onboarding

Chorus speaks text prepared by Codex, Claude Code, or Grok through **Chorus.app** (menu bar) via the MCP tool `speak`.

## First installation

1. Build the project (`swift build -c release` under Xcode 27 beta).
2. Run `.build/release/chorus install`.
3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. Open **Chorus** from Applications (or wait for LaunchAgent at login).
5. Confirm the host registered MCP server `chorus`.
6. **Claude Code:** restart so `speak` / `mcp__chorus__speak` (and `install`) appear; skills under `~/.claude/skills`.
7. **Grok:** run **`/mcps`** so `chorus__speak` and `chorus__install` appear; skills under `~/.grok/skills` (`chorus-setup`, `chorus-install`, `chorus-speak`). Call tools via `search_tool` / `use_tool` when required.
8. In Codex, review the three start-family hook definitions in `/hooks`.
9. Ask the agent for a short spoken summary via MCP speak (`text`, `voice`, `speed`, `volume`; optional `priority`).

Use `--codex`, `--claude`, and/or `--grok` to limit host integration, and `--repair` to restore owned files without overwriting unrelated settings.

## Daily use

Control everything from the **menu bar**:

- **Mode** — `normal` (default), `focus` / `quiet` / `night` (suppress subagent speech), `verbose` (include subagent); quiet/night also lower volume ceilings
- **Mute** — pause or restore speech
- **진단** — doctor findings; copy full report
- **Start / Stop service** — TTS service only
- **Chorus 종료** — quit (disables auto-start until reinstall)

There is no user CLI for mute/mode/status/speak. Agents call the MCP `speak` tool; hosts spawn `…/chorus mcp` automatically after install.

Agents are responsible for the spoken text and must always specify voice, speed, and volume. Optional `priority` is `main` (default) or `subagent`. Do not put speech JSON or HTML comments in the chat body. Chorus performs no text generation or summarization.
