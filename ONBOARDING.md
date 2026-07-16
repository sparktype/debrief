# Chorus onboarding

Chorus speaks text prepared by Codex or Claude Code through one local Swift executable.

## First installation

1. Build or obtain the `chorus` executable.
2. Run `chorus install`.
3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. In Codex, review the five installed definitions in `/hooks`.
5. Run `chorus status`; use `chorus doctor` if a check fails.
6. Ask the agent for a short explicit speech test with voice, speed, and volume.

The installer supports both hosts by default. Use `--codex` or `--claude` to limit host integration, and `--repair` to restore owned files without overwriting unrelated settings.

## Daily use

- Use `/chorus:mode` to select `normal`, `focus`, `quiet`, `verbose`, or `night`.
- Use `/chorus:mute` to pause or restore speech.
- Use `/chorus:speak` for an explicit audible message.
- Use `/chorus:status` and `/chorus:doctor` for current-state checks.

Agents are responsible for the spoken text and must always specify voice, speed, and volume. Chorus performs no text generation or summarization.
