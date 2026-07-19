# Chorus

Chorus is a local, TTS-only companion for Codex, Claude Code, and Grok on Apple Silicon Macs. It installs as **Chorus.app**, hosts TTS in a menu bar process, registers an MCP `speak` tool, wires start-family host hooks, and speaks only text supplied by the agent through MCP.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Codex, Claude Code, and/or Grok
- **Xcode 27 beta** for build (`/Applications/Xcode-beta.app`)

## Build and install

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build -c release
.build/release/chorus install
```

`chorus install` creates **Chorus.app** in `/Applications` when writable (otherwise `~/Applications`), installs the pinned Supertonic 3 model, LaunchAgent, MCP registration, start-family host hooks (plus a setup skill; Grok also gets a speak skill). There is **no user CLI** — mute, mode, start/stop, and quit live on the menu bar only.

Double-click **Chorus** in Applications (or use Spotlight) to open the menu bar. LaunchAgent also starts the app at login.

Use `chorus install --repair` from a build tree if the app is missing or broken. Limit hosts with `--codex`, `--claude`, and/or `--grok`. Codex users should review hook definitions in `/hooks` after installation.

## Agent speech contract

Agents call the Chorus MCP tool `speak` (server `chorus`) once per turn:

| Field | Required | Notes |
| --- | --- | --- |
| text | yes | ≤ 800 chars spoken summary |
| voice | yes | F1…F5, M1…M5 |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 |

Do not put speech JSON or HTML comments in the chat body. Install registers MCP for Codex, Claude Code, and Grok.

Default role mapping (for `voice` / baseline speed):

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

Start-family hooks (`SessionStart`, `UserPromptSubmit`, `SubagentStart`) inject the MCP speak contract. Hosts spawn `chorus mcp` for the `speak` tool — not a CLI tool for users.

## Local state

```text
/Applications/Chorus.app/          (or ~/Applications)
~/Library/Application Support/Chorus/
~/Library/Caches/Chorus/
~/Library/LaunchAgents/com.chorus.tts.plist
```

See [ONBOARDING.md](ONBOARDING.md) for first use and [DEVELOPER.md](DEVELOPER.md) for implementation details.
