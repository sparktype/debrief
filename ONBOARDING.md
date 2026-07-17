# Chorus onboarding

Chorus speaks text prepared by Codex or Claude Code through **Chorus.app** (menu bar).

## First installation

1. Build the project (`swift build -c release` under Xcode 27 beta).
2. Run `.build/release/chorus install`.
3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. Open **Chorus** from Applications (or wait for LaunchAgent at login).
5. In Codex, review the five installed hook definitions in `/hooks`.
6. Ask the agent for a short explicit speech test with voice, speed, and volume (speech envelope).

Use `--codex` or `--claude` to limit host integration, and `--repair` to restore owned files without overwriting unrelated settings.

## Daily use

Control everything from the **menu bar**:

- **Mode** — `normal`, `focus`, `quiet`, `verbose`, or `night`
- **Mute** — pause or restore speech
- **Start / Stop service** — TTS service only
- **Chorus 종료** — quit (disables auto-start until reinstall)

There is no user CLI for mute/mode/status/speak. Agents emit speech via the HTML envelope; hooks call the app binary automatically.

Agents are responsible for the spoken text and must always specify voice, speed, and volume. Chorus performs no text generation or summarization.
