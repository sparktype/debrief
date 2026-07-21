# Chorus developer guide

## Product boundary

Chorus is a macOS 14+ Apple Silicon TTS service delivered as one Swift executable. Its responsibilities are deliberately narrow:

1. install and verify the pinned Supertonic 3 model;
2. install the executable, LaunchAgent, host MCP registration, skills (`setup` / `install` / `speak`), and start-family hooks (Claude/Codex only);
3. accept agent MCP tools:
   - **`speak`**: `text`, `voice`, `speed`, `volume`; optional `priority`, `lane` (`companion`|`work`), `emotion`;
   - **`install`**: optional `hosts`, optional `repair` (default `true`);
4. synthesize with the local ONNX Runtime backend and play audio;
5. expose diagnostics on the menu bar (**진단**, **도우미 음성** toggle, `last-error.json`).

The coding agent owns summarization and selects spoken text and voice parameters.

## Source layout

```text
Package.swift
Sources/
├── ChorusCLI/
│   ├── main.swift             subcommand dispatch (menubar / mcp / hook / install)
│   ├── MenuBarApp.swift       LSUIElement NSStatusItem + NSMenu host
│   ├── MenuBarIcons.swift     badge / silhouette icon rendering
│   └── MenuBarModel.swift     menu actions against ResidentService
└── ChorusCore/
    ├── ResidentService.swift  pid + socket + in-process daemon lifecycle
    ├── ChorusDaemon.swift     speech accept loop over Unix socket
    ├── SpeechEnvelope.swift   internal wire model and validation
    ├── SpeechRequest.swift    envelope + SpeechPriority (main/subagent)
    ├── McpServer.swift        stdio JSON-RPC MCP (tools: speak, install)
    ├── McpSpeakTool.swift     speak arg parse + UDS submit
    ├── McpInstallTool.swift   install/repair via RuntimeInstaller
    ├── McpTomlConfig.swift    Codex/Grok TOML MCP ownership markers
    ├── HookAdapters.swift     Codex and Claude event adaptation
    ├── ModePolicy.swift       mute / subagent suppress / volume ceiling
    ├── SpeechQueue.swift      bounded serialized speech queue
    ├── SupertonicEngine.swift local ONNX TTS backend
    ├── UnixSocket.swift       local resident transport
    ├── MenuBarStatus.swift    pure status snapshot for menu header
    ├── ModelInstaller.swift   pinned download, checksum, and atomic swap
    ├── RuntimeInstaller.swift executable and LaunchAgent lifecycle
    ├── EmbeddedTemplates.swift hooks, skills (Claude/Codex + Grok variants)
    ├── HostInstaller.swift    safe hook/skill/MCP merge/uninstall
    ├── LegacyMigration.swift  one-time allowlisted configuration import
    └── Diagnostics.swift      status, doctor findings, last-error
SwiftTests/
├── ChorusCoreTests/
└── ChorusIntegrationTests/
plugins/chorus/               marketplace metadata, hooks, skills
docs/archive/                 superseded Python-era designs (not product truth)
.github/workflows/ci.yml      macos-15 swift test + release build
```

## Process model

```text
Login / chorus install
        │
        ▼
LaunchAgent (com.chorus.tts)
        │ ProgramArguments: [Chorus.app/Contents/MacOS/chorus, "menubar"]
        ▼
Chorus.app (LSUIElement menu bar)
        ├── Menu: status · 진단 · mute · mode · start · stop · quit
        └── ResidentService (in-process)
              ├── pid file
              ├── Unix socket server
              ├── ChorusDaemon + SpeechQueue
              ├── SupertonicEngine
              └── AudioPlayer

Codex / Claude / Grok
  │ spawn: …/chorus mcp   (stdio MCP)
  ▼
chorus mcp
  ├── tools/call speak   → validate → UDS → ResidentService
  └── tools/call install → RuntimeInstaller (same as CLI install)
```

## Host install paths

| Host | Settings / MCP | Skills | Hooks |
| --- | --- | --- | --- |
| Codex | `~/.codex/config.toml` → `[mcp_servers.chorus]` | `~/.agents/skills/chorus-*` | start-family in `~/.codex/hooks.json` |
| Claude | `~/.claude/settings.json` → `mcpServers.chorus` | `~/.claude/skills/chorus-*` | start-family in settings |
| Grok | `~/.grok/config.toml` → `[mcp_servers.chorus]` | `~/.grok/skills/chorus-*` | **none** (SessionStart stdout ignored) |

Skills installed for every host: **`chorus-setup`**, **`chorus-install`**, **`chorus-speak`**. Grok skill bodies use Grok tool names (`chorus__speak` / `chorus__install`) and `/mcps`.

MCP registration always points at the app absolute path with `args: ["mcp"]`. TOML hosts use ownership markers `# BEGIN chorus-mcp` / `# END chorus-mcp`. `tool_timeout_sec = 120` (install may run longer than speak).

## Speech contract (MCP `speak`)

| Field | Constraints |
| --- | --- |
| text | non-empty, ≤ 800 chars |
| voice | F1…F5, M1…M5 |
| speed | 0.7–2.0 finite |
| volume | 0.0–1.0 finite |
| priority | optional: `main` (default) or `subagent` |
| lane | optional: `companion` (default) or `work` |
| emotion | optional closed enum; prosody bias only |

No HTML comments or speech JSON in the chat body. Omitting the tool produces silence. Internal `SpeechEnvelope` validation backs UDS frames after MCP parse. `SpeechRequest.priority` drives `ModePolicy` and queue main/subagent rules (not host hook event names).

Host tool display names:

| Host | speak | install |
| --- | --- | --- |
| Claude Code | `mcp__chorus__speak` | `mcp__chorus__install` |
| Grok | `chorus__speak` | `chorus__install` |
| Codex | `speak` | `install` |

## MCP tool `install`

| Field | Constraints |
| --- | --- |
| hosts | optional array of `codex` / `claude` / `grok` (omit = all) |
| repair | optional boolean (default `true`) |

Uses the MCP process executable as the source binary for `RuntimeInstaller` (same path as CLI `chorus install`). Prefer shell install for first-time model download if the host tool timeout is short.

## Runtime lifecycle

`chorus install` installs `Chorus.app`, pinned model, host MCP, skills, Claude/Codex start-family hooks, LaunchAgent, and health-gated legacy cutover. There is no user CLI symlink under `~/.local/bin`. Owned-file digests prevent uninstall/repair from overwriting user-modified files.

Menu Stop ends the in-process TTS service only; the menu bar process stays up under LaunchAgent KeepAlive. Menu Quit calls `launchctl disable` on `com.chorus.tts` (so KeepAlive will not relaunch), stops the service, then `exit(0)`. Do not await `launchctl bootout` from inside the job — that deadlocks. `install --repair` re-enables and bootstraps the agent.

Synthesis/playback failures and queue rejections write `~/Library/Caches/Chorus/last-error.json` and appear under the menu **진단** submenu.

## Build and verification

```sh
./scripts/with-xcode.sh swift test
./scripts/with-xcode.sh swift build -c release
```

GitHub Actions (`.github/workflows/ci.yml`) runs `swift test` and `swift build -c release` on `macos-15`. Local development prefers Xcode 27 beta via `./scripts/with-xcode.sh` or `.envrc` `DEVELOPER_DIR`.

Release verification should also inspect architecture (`arm64`) and run install + offline speech smoke tests from a clean temporary home when models are available (`CHORUS_TEST_MODEL_DIR` for the real-model smoke test).

## Change rules

- Add a focused failing test before behavior changes.
- Run impact analysis before editing an existing symbol (GitNexus when available).
- Keep the hook set exact (start-family only on Claude/Codex). Skills are `setup` + `install` + `speak` (Grok via `grokSkills`). MCP tools are `speak` + `install`.
- Do not persist hook payload text or synthesized audio.
- Preserve unrelated host settings and modified installed files.
- Do not reintroduce Python, Node, HTTP TTS servers, STT, or HTML speech envelopes.
- Run the full Swift suite and release build before claiming completion.

## Active specs

| Spec | Topic |
| --- | --- |
| `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` | Single-binary Swift TTS (envelope contract superseded) |
| `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` | Menu bar resident process |
| `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` | MCP speak + Grok (see errata at top for install tool / priority) |

Older material lives under `docs/archive/` and is not product truth.
