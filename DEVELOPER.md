# Chorus developer guide

## Product boundary

Chorus is a macOS 14+ Apple Silicon TTS service delivered as one Swift executable. Its responsibilities are deliberately narrow:

1. install and verify the pinned Supertonic 3 model;
2. install the executable, LaunchAgent, start-family host hooks, setup skill, and MCP registration (plus Grok speak skill);
3. accept strict agent-provided MCP `speak` arguments (`text`, `voice`, `speed`, `volume`; optional `priority`);
4. synthesize with the local ONNX Runtime backend and play audio;
5. expose current-state diagnostics on the menu bar (**진단** submenu + last-error file).

The coding agent owns summarization and selects text, voice, speed, and volume via the MCP tool.

## Source layout

```text
Package.swift
Sources/
├── ChorusCLI/                 command parsing and process entry point
│   ├── main.swift             subcommand dispatch (menubar / daemon / mcp / CLI)
│   ├── MenuBarApp.swift       LSUIElement NSStatusItem + NSMenu host
│   ├── MenuBarIcons.swift     badge / silhouette icon rendering
│   └── MenuBarModel.swift     menu actions against ResidentService
└── ChorusCore/
    ├── ResidentService.swift  pid + socket + in-process daemon lifecycle
    ├── ChorusDaemon.swift     speech accept loop over Unix socket
    ├── SpeechEnvelope.swift   internal wire model and validation
    ├── SpeechRequest.swift    envelope + SpeechPriority (main/subagent)
    ├── McpServer.swift        stdio JSON-RPC MCP (tools only)
    ├── McpSpeakTool.swift     speak arg parse + UDS submit
    ├── McpTomlConfig.swift    Codex/Grok TOML MCP ownership markers
    ├── HookAdapters.swift     Codex and Claude event adaptation
    ├── ModePolicy.swift       mute / subagent suppress / volume ceiling
    ├── SpeechQueue.swift      bounded serialized speech queue
    ├── SupertonicEngine.swift local ONNX TTS backend
    ├── UnixSocket.swift       local resident transport
    ├── MenuBarStatus.swift    pure status snapshot for menu header
    ├── ModelInstaller.swift   pinned download, checksum, and atomic swap
    ├── RuntimeInstaller.swift executable and LaunchAgent lifecycle
    ├── EmbeddedTemplates.swift hooks, skills, LaunchAgent (args: menubar)
    ├── HostInstaller.swift    safe hook/skill/MCP merge/uninstall (incl. Grok)
    ├── LegacyMigration.swift  one-time allowlisted configuration import
    └── Diagnostics.swift      status, doctor findings, last-error
SwiftTests/
├── ChorusCoreTests/
└── ChorusIntegrationTests/
plugins/chorus/               marketplace metadata, start-family hooks, setup skill
docs/archive/                 superseded Python-era designs (not product truth)
```

## Process model

```text
Login / chorus install
        │
        ▼
LaunchAgent (com.chorus.tts)
        │ ProgramArguments: [Chorus.app/Contents/MacOS/chorus, "menubar"]
        ▼
Chorus.app (LSUIElement menu bar; also launched from Applications)
        ├── Menu: status · mute · mode · start · stop · quit
        └── ResidentService (in-process)
              ├── pid file
              ├── Unix socket server
              ├── ChorusDaemon + SpeechQueue
              ├── SupertonicEngine
              └── AudioPlayer

Codex / Claude / Grok
  │ spawn: …/chorus mcp   (stdio MCP; tool speak)
  ▼
chorus mcp ──► validate ──► Unix socket ──► ResidentService

Codex / Claude (start hooks only)
  │ SessionStart / UserPromptSubmit / SubagentStart
  ▼
…/chorus hook ──► inject MCP speak contract context
```

## Host install paths

| Host | Settings / MCP | Skills | Hooks |
| --- | --- | --- | --- |
| Codex | `~/.codex/config.toml` → `[mcp_servers.chorus]` | `~/.agents/skills` | start-family in `~/.codex/hooks.json` |
| Claude | `~/.claude/settings.json` → `mcpServers.chorus` | `~/.claude/skills` | start-family in settings |
| Grok | `~/.grok/config.toml` → `[mcp_servers.chorus]` | `~/.grok/skills/chorus-speak` | none (skill + MCP carry contract) |

MCP registration always points at the app absolute path with `args: ["mcp"]`.

## Speech contract (MCP)

Agents call tool `speak` on server `chorus` once per turn. Required arguments:

| Field | Constraints |
| --- | --- |
| text | non-empty, ≤ 800 chars |
| voice | F1…F5, M1…M5 |
| speed | 0.7–2.0 finite |
| volume | 0.0–1.0 finite |
| priority | optional: `main` (default) or `subagent` |

### MCP tool `install`

| Field | Constraints |
| --- | --- |
| hosts | optional array of `codex` / `claude` / `grok` (omit = all) |
| repair | optional boolean (default `true`) |

Runs the same `RuntimeInstaller` path as CLI `chorus install` using the MCP process executable as the source binary. Prefer shell install for first-time model download if the host tool timeout is short.

No HTML comments or speech JSON in the chat body. Omitting the tool produces silence (no envelope fallback). Internal `SpeechEnvelope` validation still backs UDS frames after MCP parse. `SpeechRequest.priority` drives `ModePolicy` and queue main/subagent rules — not host hook event names.

Synthesis/playback failures and queue rejections write `~/Library/Caches/Chorus/last-error.json` and appear under the menu **진단** submenu.

## Runtime lifecycle

`chorus install` installs `Chorus.app` (MacOS binary + Info.plist + optional AppIcon.icns), pinned model, host hooks (start-family), MCP registration, a single setup skill (and Grok speak skill), LaunchAgent replacement, and a health-gated legacy cutover. There is no user CLI and no `~/.local/bin/chorus` symlink; hooks and MCP invoke the app executable directly. Owned-file digests prevent uninstall or repair from overwriting user modifications. LaunchAgent `ProgramArguments` are `[appExecutable, "menubar"]`. Finder opens the app with no arguments (menu bar).

The menu bar resident starts `ResidentService`, which writes its PID and serves the local Unix domain socket under the Chorus home. Speech requests are bounded, deduplicated, serialized, and played through the system audio framework. Menu Stop ends the in-process service only; the menu bar process stays up under LaunchAgent KeepAlive. Menu Quit calls `launchctl disable` on `com.chorus.tts` (so KeepAlive will not relaunch), stops the service, then `exit(0)`. It must not await `launchctl bootout` from inside the job — launchd waits for the process to exit and that deadlocks. `install --repair` re-enables and bootstraps the agent.

## Build and verification

```sh
swift test
swift build -c release
```

On the Command Line Tools 27 toolchain, the local environment may require the Testing plugin and runtime search-path flags documented in the implementation plan. Release verification must also inspect the executable architecture and linked libraries, then run installation and offline speech smoke tests from a clean temporary home.

GitHub Actions (`.github/workflows/ci.yml`) runs `swift test` and `swift build -c release` on `macos-15`. Local development still prefers Xcode 27 beta via `./scripts/with-xcode.sh`.

## Change rules

- Add a focused failing test before behavior changes.
- Run impact analysis before editing an existing symbol.
- Keep the hook set exact (start-family only). Skills for Claude/Codex are `setup` + `install` + `speak`; MCP tools are `speak` + `install`. Grok gets `chorus-speak` via its install path. Additions are product-scope changes.
- Do not persist hook payload text or synthesized audio.
- Preserve unrelated host settings and modified installed files.
- Run the full Swift suite and release build before claiming completion.
