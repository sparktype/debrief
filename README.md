# Chorus

Chorus is a local, **TTS-only** companion for Codex, Claude Code, and Grok on Apple Silicon Macs. It installs as **Chorus.app**, runs a menu bar resident process, exposes MCP tools `speak` and `install`, wires start-family host hooks (Claude/Codex), and speaks only text the agent supplies through MCP.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Codex, Claude Code, and/or Grok
- **Xcode 27 beta** for build (`/Applications/Xcode-beta.app`)

## Build and install

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
# or: ./scripts/with-xcode.sh
swift build -c release
.build/release/chorus install
```

`chorus install` creates **Chorus.app** in `/Applications` when writable (otherwise `~/Applications`), installs the pinned Supertonic 3 model, LaunchAgent, MCP registration, skills, and (for Claude/Codex) start-family hooks.

| Host | After install |
| --- | --- |
| **Claude Code** | `mcpServers.chorus` in `~/.claude/settings.json`; skills under `~/.claude/skills`; restart Claude so tools load |
| **Codex** | MCP in `~/.codex/config.toml`; hooks in `~/.codex/hooks.json` (review `/hooks`); skills under `~/.agents/skills` |
| **Grok** | MCP in `~/.grok/config.toml`; skills under `~/.grok/skills`; **no hooks** — run `/mcps` to refresh tools |

Limit hosts with `--codex`, `--claude`, and/or `--grok`. Use `--repair` to restore owned files without overwriting user-modified settings.

There is **no user CLI** for mute/mode/status/speak. Control those from the menu bar only. Agents use MCP; hooks/MCP always point at the **app absolute path**.

Double-click **Chorus** in Applications (or Spotlight) to open the menu bar. LaunchAgent also starts the app at login.

## MCP tools

Server name: **`chorus`**.

| Tool | Claude | Grok | Purpose |
| --- | --- | --- | --- |
| `speak` | `mcp__chorus__speak` | `chorus__speak` | Spoken turn summary |
| `install` | `mcp__chorus__install` | `chorus__install` | Install/repair host wiring + model check |

Grok discovers tools with `search_tool` / `use_tool` when required.

### `speak` arguments

| Field | Required | Notes |
| --- | --- | --- |
| text | yes | ≤ 800 chars; prefer observe + meaning + one next step |
| voice | yes | F1…F5, M1…M5 (companion prefers F1) |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 |
| priority | no | `main` (default) or `subagent`; focus/quiet/night suppress subagent |
| lane | no | `companion` (default reflective) or `work` (factual) |
| emotion | no | `neutral` · `warm` · `focused` · `concerned` · `relieved` · `tired` (prosody bias) |

Prefer a **reflective companion** line when speech helps; **silence is OK** when it would only read on-screen lists. Do **not** put speech JSON or HTML comments in the chat body.

### `install` arguments

| Field | Default | Notes |
| --- | --- | --- |
| hosts | all | Array: `codex`, `claude`, `grok` |
| repair | `true` | Re-verify model and re-merge owned hooks/MCP/skills |

After install: Claude → restart; Grok → `/mcps`. First-time model download may exceed short MCP timeouts — use shell install if needed.

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
| Status header | Running / muted / mode / active voice |
| 진단 | Doctor findings; copy full report to pasteboard |
| Mute | Toggle mute |
| 도우미 음성 | Enable/disable companion-lane speech |
| Mode | See modes below |
| Start / Stop service | In-process TTS service |
| Chorus 종료 | Quit (disables LaunchAgent so KeepAlive does not relaunch) |

### Modes

| Mode | Effect |
| --- | --- |
| `normal` | Default; main and subagent speech play; volume ceiling 1.0 |
| `focus` | Suppress `priority=subagent` |
| `quiet` | Volume ceiling 0.45; suppress subagent |
| `verbose` | Include subagent; volume ceiling 1.0 |
| `night` | Volume ceiling 0.20; suppress subagent |

Claude/Codex start-family hooks inject the speak contract. Grok relies on skills + MCP tool descriptions (SessionStart stdout is ignored).

## Local state

```text
/Applications/Chorus.app/          (or ~/Applications)
~/Library/Application Support/Chorus/
~/Library/Caches/Chorus/           # socket, last-error.json, …
~/Library/LaunchAgents/com.chorus.tts.plist
```

## Docs

| Doc | Audience |
| --- | --- |
| [ONBOARDING.md](ONBOARDING.md) | First use |
| [DEVELOPER.md](DEVELOPER.md) | Build, architecture, change rules |
| [docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md](docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md) | Approved MCP design (+ errata) |
| [docs/archive/](docs/archive/) | Superseded Python-era notes only |
