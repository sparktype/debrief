# debrief developer guide

## Product boundary

debrief is a macOS 14+ Apple Silicon TTS service delivered as one Swift executable. Its responsibilities are deliberately narrow:

1. install and verify the pinned Supertonic 3 model;
2. install the executable, LaunchAgent, host MCP registration, skills (`setup` / `install` / `speak`), and start-family hooks (Claude/Codex only);
3. accept agent MCP tools:
   - **`speak`**: `text`, `voice`, `speed`, `volume`; optional `priority`, `lane` (`companion`|`work`), `emotion`;
   - **`install`**: optional `hosts`, optional `repair` (default `true`);
4. synthesize with the local ONNX Runtime backend and play audio;
5. expose diagnostics through `debrief status` and `debrief doctor` (`last-error.json`).

The coding agent owns summarization and selects spoken text and voice parameters.

## Source layout

```text
Package.swift
Sources/
├── DebriefCLI/
│   └── EntryPoint.swift       daemon, CLI controls, mcp, hook, install
└── DebriefCore/
    ├── ResidentService.swift  pid + socket + daemon lifecycle
    ├── DebriefDaemon.swift     speech accept loop over Unix socket
    ├── SpeechEnvelope.swift   internal wire model and validation
    ├── SpeechRequest.swift    envelope + SpeechPriority + lane + emotion
    ├── SpeechLane.swift       companion | work
    ├── SpeechEmotion.swift    closed emotion enum + EmotionProsody bias
    ├── McpServer.swift        stdio JSON-RPC MCP (tools: speak, install)
    ├── McpSpeakTool.swift     speak arg parse + UDS submit
    ├── McpInstallTool.swift   install/repair via RuntimeInstaller
    ├── McpTomlConfig.swift    Codex/Grok TOML MCP ownership markers
    ├── HookAdapters.swift     Codex and Claude event adaptation
    ├── ModePolicy.swift       mute / companionEnabled / subagent suppress / volume ceiling
    ├── SpeechQueue.swift      bounded serialized speech queue
    ├── SupertonicEngine.swift local ONNX TTS backend
    ├── UnixSocket.swift       local resident transport
    ├── ModelInstaller.swift   pinned download, checksum, and atomic swap
    ├── RuntimeInstaller.swift executable and LaunchAgent lifecycle
    ├── EmbeddedTemplates.swift hooks, skills (Claude/Codex + Grok variants)
    ├── HostInstaller.swift    safe hook/skill/MCP merge/uninstall
    ├── LegacyMigration.swift  one-time allowlisted configuration import
    └── Diagnostics.swift      status, doctor findings, last-error
SwiftTests/
├── DebriefCoreTests/
└── DebriefIntegrationTests/
plugins/debrief/               marketplace metadata, hooks, skills
docs/archive/                 superseded Python-era designs (not product truth)
.github/workflows/ci.yml      macos-15 swift test + release build
```

## Process model

```text
debrief install
        │ copies ~/.local/bin/debrief
        ▼
LaunchAgent (com.debrief.tts, gui/<uid>, KeepAlive)
        │ ProgramArguments: [~/.local/bin/debrief, "daemon"]
        ▼
debrief daemon
        └── ResidentService
              ├── pid file
              ├── Unix socket server
              ├── DebriefDaemon + SpeechQueue
              ├── SupertonicEngine
              └── AudioPlayer

debrief mute | mode | companion | status | doctor | start | stop

Codex / Claude / Grok
  │ spawn: ~/.local/bin/debrief mcp   (stdio MCP)
  ▼
debrief mcp
  ├── tools/call speak   → validate → UDS → ResidentService
  └── tools/call install → RuntimeInstaller (same as CLI install)
```

## Host install paths

| Host | Settings / MCP | Skills | Hooks |
| --- | --- | --- | --- |
| Codex | `~/.codex/config.toml` → `[mcp_servers.debrief]` | `~/.agents/skills/debrief-*` | start-family in `~/.codex/hooks.json` |
| Claude | `~/.claude/settings.json` → `mcpServers["debrief"]` | `~/.claude/skills/debrief-*` | start-family in settings |
| Grok | `~/.grok/config.toml` → `[mcp_servers.debrief]` | `~/.grok/skills/debrief-*` | **none** (SessionStart stdout ignored) |

Skills installed for every host: **`debrief-setup`**, **`debrief-install`**, **`debrief-speak`**. Grok skill bodies use Grok tool names (`debrief__speak` / `debrief__install`) and `/mcps`.

MCP registration points at `~/.local/bin/debrief` with `args: ["mcp"]`. TOML hosts use ownership markers `# BEGIN debrief-mcp` / `# END debrief-mcp`. `tool_timeout_sec = 120` (install may run longer than speak).

## Speech contract (MCP `speak`)

| Field | Constraints |
| --- | --- |
| text | non-empty, ≤ 800 chars |
| voice | F1…F5, M1…M5 |
| speed | 0.7–2.0 finite |
| volume | 0.0–1.0 finite |
| priority | optional: `main` (default) or `subagent` |
| lane | optional: `companion` (default) or `work` |
| emotion | optional: `neutral` · `warm` · `focused` · `concerned` · `relieved` · `tired` (default `neutral`); prosody bias only |

No HTML comments or speech JSON in the chat body. Each user-visible turn is one spoken line: what changed, then one next action. After code work the next action names what the user must verify to keep code ownership (cognitive-debt reduction); wording only, not enforced in code. Silence only if nothing new and no next action. The agent writes the line. Internal `SpeechEnvelope` validation backs UDS frames after MCP parse.

Policy (`ModePolicy.admit`):

- **mute** rejects all speech
- **`companionEnabled == false`** (`debrief companion off`) rejects `lane=companion`; work lane still plays
- **focus / quiet / night** reject `priority=subagent`
- **quiet / night** apply volume ceilings (0.45 / 0.20)
- **work** lane forces neutral emotion for prosody

`SpeechRequest.priority` / `lane` / `emotion` are request fields (not host hook event names).

Host tool display names:

| Host | speak | install |
| --- | --- | --- |
| Claude Code | `mcp__debrief__speak` | `mcp__debrief__install` |
| Grok | `debrief__speak` | `debrief__install` |
| Codex | `speak` | `install` |

## MCP tool `install`

| Field | Constraints |
| --- | --- |
| hosts | optional array of `codex` / `claude` / `grok` (omit = all) |
| repair | optional boolean (default `true`) |

Uses the MCP process executable as the source binary for `RuntimeInstaller` (same path as CLI `debrief install`). Prefer shell install for first-time model download if the host tool timeout is short.

## Runtime lifecycle

`debrief install` copies the executable to `~/.local/bin/debrief` (atomic write, mode 0755; a directory at that path is refused), installs the pinned model, host MCP, skills, Claude/Codex start-family hooks, and LaunchAgent `com.debrief.tts`. Bootstrap is `enable`, `bootout`, `bootstrap`, with one retry. Owned-file digests prevent uninstall from removing a binary whose contents differ from the manifest.

`debrief start` bootstraps the existing plist and does not rewrite it. A live pid prints `이미 실행 중입니다.` and does not bootout. `debrief stop` disables and bootouts the job, keeps the plist and the binary, and prints `서비스를 중지했습니다.` `debrief daemon` parks until SIGTERM or SIGINT. A second live daemon exits 0. A missing model records `last-error.json`, skips the socket, and stays running so KeepAlive does not spin.

Synthesis/playback failures and queue rejections write `~/Library/Caches/debrief/last-error.json`. `debrief doctor` prints them.

## Build and verification

```sh
./scripts/with-xcode.sh swift test
./scripts/with-xcode.sh swift build -c release
```

GitHub Actions (`.github/workflows/ci.yml`) runs `swift test` and `swift build -c release` on `macos-15`, then checks that `.build/release/debrief` is an arm64 binary. Local development uses Xcode 27 via `./scripts/with-xcode.sh` (Xcode-beta when installed, otherwise Xcode.app). Override with `DEBRIEF_XCODE_DEVELOPER`.

The repository is [github.com/sparktype/debrief](https://github.com/sparktype/debrief). `DebriefVersion.current` is `0.0.5`, tag `v0.0.5`. The tap formula is `sparktype/tap/debrief` (`class Debrief`, `swift build --product debrief`). Install with `brew install sparktype/tap/debrief`, then `debrief install`. `Formula/chorus.rb` remains on the tap for tag `v0.0.1` and builds the previous `chorus` binary. A source checkout still builds with `./scripts/with-xcode.sh swift build -c release`.

Release verification should also inspect architecture (`arm64`) and run install + offline speech smoke tests from a clean temporary home when models are available (`DEBRIEF_TEST_MODEL_DIR` for the real-model smoke test).

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
| `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` | Earlier menu-bar process (superseded for packaging) |
| `docs/superpowers/specs/2026-09-29-daemon-single-binary-design.md` | Headless daemon and CLI controls (implemented; body still says chorus) |
| `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` | MCP speak + install + Grok (see errata for product truth) |
| `docs/superpowers/specs/2026-07-22-reflective-companion-design.md` | Lane, emotion, 도우미 음성 (attitude/timing superseded 2026-09-29 by the turn briefing) |

Older material lives under `docs/archive/` and is not product truth.
