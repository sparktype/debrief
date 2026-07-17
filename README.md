# Chorus

Chorus is a local, TTS-only companion for Codex and Claude Code on Apple Silicon Macs. One Swift executable installs the pinned Supertonic 3 model, hosts the resident TTS service in a menu bar process, installs host hooks and skills, and speaks only text explicitly supplied by an agent.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Codex or Claude Code

## Build and install

```sh
swift build -c release
.build/release/chorus install
```

`chorus install` copies the executable to `~/.local/share/chorus/bin/chorus`, downloads and verifies the pinned model on first installation, installs the LaunchAgent, and merges the five Chorus hooks and six skills for both supported hosts. Use `chorus install --repair` to restore missing or damaged owned files.

After install, LaunchAgent (`com.chorus.tts`) runs `chorus menubar`. That process is an LSUIElement menu bar app that hosts the TTS service in-process. The menu controls mute, mode, service start/stop, and Quit. Quit disables the LaunchAgent (so KeepAlive does not relaunch) and exits; it does not wait on `bootout` from inside the job (that deadlocks with launchd). Re-enable later with `chorus install --repair`. CLI subcommands remain for hooks, install, status, doctor, speak, mute, and mode. `chorus daemon` is a headless debug path and is not the install LaunchAgent target.

Codex users should review the installed definitions in `/hooks` after installation.

## Agent speech contract

Agents provide a strict invisible envelope in their response:

```text
<!-- chorus:speak {"v":1,"text":"Build completed.","voice":"F1","speed":0.93,"volume":0.85} -->
```

`v`, `text`, `voice`, `speed`, and `volume` are all required. Chorus does not generate or rewrite summaries. Codex or Claude Code selects the text and all voice controls.

Default role mapping:

| Role | Voice | Speed |
| --- | --- | --- |
| reviewer / optimizer | M3 | 1.00 |
| planner | M1 | 1.10 |
| builder | M4 | 0.95 |
| tester | F2 | 1.10 |
| explorer | F3 | 1.00 |
| guardian | M5 | 0.88 |
| ops | F4 | 1.05 |
| specialist | F5 | 0.88 |
| default | F1 | 0.93 |

The agent must also provide volume. The selected mode may suppress speech or cap its effective volume, but it does not replace the agent's voice or speed.

## Commands and skills

| Command | Skill | Purpose |
| --- | --- | --- |
| `chorus install [--repair]` | `/chorus:setup` | Install or repair the binary, model, resident service, hooks, and skills |
| `chorus status` | `/chorus:status` | Show current installation and resident process state |
| `chorus doctor` | `/chorus:doctor` | Diagnose failures with recovery commands |
| `chorus mode [name]` | `/chorus:mode` | Show or set `normal`, `focus`, `quiet`, `verbose`, or `night` |
| `chorus mute [on|off|toggle]` | `/chorus:mute` | Show or change mute state |
| `chorus speak ...` | `/chorus:speak` | Speak explicit text with required controls |
| `chorus menubar` | — | Menu bar resident (LaunchAgent default); mute/mode/start/stop |
| `chorus daemon` | — | Headless resident for debug; not the install path |

The installed hooks are exactly `SessionStart`, `UserPromptSubmit`, `SubagentStart`, `Stop`, and `SubagentStop`.

## Local state

```text
~/.local/share/chorus/
├── bin/chorus
├── models/supertonic-3/
├── config.json
├── state/
└── run/
```

See [ONBOARDING.md](ONBOARDING.md) for first use and [DEVELOPER.md](DEVELOPER.md) for implementation details.
