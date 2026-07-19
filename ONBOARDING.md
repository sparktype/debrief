# Chorus onboarding

Chorus speaks text prepared by Codex, Claude Code, or Grok through **Chorus.app** (menu bar) via the MCP tool `speak`.

## First installation

1. Build the project (`swift build -c release` under Xcode 27 beta).
2. Run `.build/release/chorus install`.
3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. Open **Chorus** from Applications (or wait for LaunchAgent at login).
5. Confirm the host registered MCP server `chorus` (and for Grok, refresh tools with `/mcps` if needed).
6. In Codex, review the three start-family hook definitions in `/hooks`.
7. Ask the agent for a short spoken summary by calling MCP tool `speak` with `text`, `voice`, `speed`, and `volume`.

Use `--codex`, `--claude`, and/or `--grok` to limit host integration, and `--repair` to restore owned files without overwriting unrelated settings.

## Daily use

Control everything from the **menu bar**:

- **Mode** — `normal`, `focus`, `quiet`, `verbose`, or `night`
- **Mute** — pause or restore speech
- **Start / Stop service** — TTS service only
- **Chorus 종료** — quit (disables auto-start until reinstall)

There is no user CLI for mute/mode/status/speak. Agents call the MCP `speak` tool; hosts spawn `…/chorus mcp` automatically after install.

Agents are responsible for the spoken text and must always specify voice, speed, and volume. Do not put speech JSON or HTML comments in the chat body. Chorus performs no text generation or summarization.
