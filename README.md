# Chorus

Chorus is a local, TTS-only companion for Codex and Claude Code on Apple Silicon Macs. It installs as **Chorus.app**, hosts TTS in a menu bar process, wires host hooks, and speaks only text supplied by an agent speech envelope.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Codex or Claude Code
- **Xcode 27 beta** for build (`/Applications/Xcode-beta.app`)

## Build and install

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build -c release
.build/release/chorus install
```

`chorus install` creates **Chorus.app** in `/Applications` when writable (otherwise `~/Applications`), installs the pinned Supertonic 3 model, LaunchAgent, and host hooks (plus a single setup skill). There is **no user CLI** — mute, mode, start/stop, and quit live on the menu bar only.

Double-click **Chorus** in Applications (or use Spotlight) to open the menu bar. LaunchAgent also starts the app at login.

Use `chorus install --repair` from a build tree if the app is missing or broken. Codex users should review hook definitions in `/hooks` after installation.

## Agent speech contract

Agents provide a strict invisible envelope in their response:

```text
<!-- chorus:speak {"v":1,"text":"Build completed.","voice":"F1","speed":0.93,"volume":0.85} -->
```

`v`, `text`, `voice`, `speed`, and `volume` are all required. Chorus does not generate or rewrite summaries.

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

## Menu bar

| Action | Purpose |
| --- | --- |
| Status header | Running / muted / mode |
| Mute | Toggle mute |
| Mode | `normal`, `focus`, `quiet`, `verbose`, `night` |
| Start / Stop service | In-process TTS service |
| Chorus 종료 | Quit (disables LaunchAgent so KeepAlive does not relaunch) |

Hooks (`SessionStart`, `UserPromptSubmit`, `SubagentStart`, `Stop`, `SubagentStop`) call the app binary with `hook --source …` — not a CLI tool for users.

## Local state

```text
/Applications/Chorus.app/          (or ~/Applications)
~/Library/Application Support/Chorus/
~/Library/Caches/Chorus/
~/Library/LaunchAgents/com.chorus.tts.plist
```

See [ONBOARDING.md](ONBOARDING.md) for first use and [DEVELOPER.md](DEVELOPER.md) for implementation details.
