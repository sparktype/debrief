# debrief developer guide

## Product boundary

debrief is a macOS 14+ Apple Silicon TTS service delivered as one Rust executable. Its responsibilities are deliberately narrow:

1. install and verify the pinned Supertonic 3 model;
2. install the executable, LaunchAgent, host MCP registration, skills (`setup` / `install` / `speak`), and start-family hooks (Claude/Codex only);
3. accept agent MCP tools:
   - **`speak`**: `text`, `voice`, `speed`, `volume`; optional `priority`, `lane` (`companion`|`work`), `emotion`, `session`;
   - **`install`**: optional `hosts`, optional `repair` (default `true`);
4. synthesize with the local ONNX Runtime backend (`ort` crate) and play audio (`cpal`);
5. expose diagnostics through `debrief status` and `debrief doctor` (`last-error.json`).

The coding agent owns summarization and selects spoken text and voice parameters.

## Source layout

```text
Cargo.toml                      workspace: debrief-core, debrief-tts, debrief
crates/
├── debrief/
│   └── src/main.rs             CLI entry point: parses DebriefCommand, routes to debrief-core
├── debrief-core/
│   └── src/
│       ├── resident_service.rs      pid + socket + daemon lifecycle
│       ├── debrief_daemon.rs        speech accept loop over Unix socket
│       ├── speech_envelope.rs       internal wire model and validation
│       ├── speech_request.rs        envelope + SpeechPriority + lane + emotion
│       ├── speech_lane.rs           companion | work
│       ├── speech_emotion.rs        closed emotion enum + EmotionProsody bias
│       ├── mcp_server.rs            stdio JSON-RPC MCP (tools: speak, install)
│       ├── mcp_speak_tool.rs        speak arg parse + UDS submit
│       ├── mcp_install_tool.rs      install/repair via RuntimeInstaller
│       ├── mcp_toml_config.rs       Codex/Grok TOML MCP ownership markers
│       ├── hook_adapter.rs          Codex and Claude event adaptation
│       ├── mode_policy.rs           mute / companion_enabled / subagent suppress / volume ceiling
│       ├── speech_queue.rs          bounded serialized speech queue
│       ├── unix_socket.rs           local resident transport
│       ├── model_installer.rs       pinned download, checksum, and atomic swap
│       ├── runtime_installer.rs     executable and LaunchAgent lifecycle
│       ├── embedded_templates.rs    hooks, skills (Claude/Codex + Grok variants)
│       ├── host_installer.rs        safe hook/skill/MCP merge/uninstall
│       └── diagnostics.rs           status, doctor findings, last-error
└── debrief-tts/
    └── src/
        ├── supertonic_engine.rs     local ONNX TTS backend (`ort` crate)
        ├── supertonic_tensor.rs     text chunking, tensor padding/mask/concat
        └── audio_player.rs          cpal playback driver
docs/archive/                 superseded Python-era designs (not product truth)
.github/workflows/ci.yml      macos-15 cargo test + clippy + release build
.github/workflows/release.yml tag push (v*) builds a release tarball
```

Swift sources (`Sources/`, `SwiftTests/`, `Package.swift`) remain in the repository as the pre-rewrite reference until the release pipeline cutover is confirmed working; they are not built or tested by CI and are not product truth.

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
| Claude | `~/.claude.json` → `mcpServers["debrief"]` | `~/.claude/skills/debrief-*` | start-family in `~/.claude/settings.json` |
| Grok | `~/.grok/config.toml` → `[mcp_servers.debrief]` | `~/.grok/skills/debrief-*` | **none** (SessionStart stdout ignored) |

Skills installed for every host: **`debrief-setup`**, **`debrief-install`**, **`debrief-speak`**. Grok skill bodies use Grok tool names (`debrief__speak` / `debrief__install`) and `/mcps`.

Claude Code reads user-scope MCP servers from `~/.claude.json` only — `mcpServers` in `~/.claude/settings.json` is ignored. `HostInstaller` strips a legacy debrief entry from `settings.json` on every install/repair and writes the registration to `~/.claude.json` instead.

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
| session | optional: host session id; keeps the companion voice |

No HTML comments or speech JSON in the chat body. Each user-visible turn is one spoken line: what changed, then one next action. After code work the next action names what the user must verify to keep code ownership (cognitive-debt reduction); wording only, not enforced in code. Silence only if nothing new and no next action. The agent writes the line. Internal `SpeechEnvelope` validation backs UDS frames after MCP parse.

Policy (`ModePolicy::admit`):

- **mute** rejects all speech
- **`companion_enabled == false`** (`debrief companion off`) rejects `lane=companion`; work lane still plays
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

`debrief install` copies the executable to `~/.local/bin/debrief` (atomic write via `renameatx_np`, mode 0755; a directory at that path is refused), installs the pinned model, host MCP, skills, Claude/Codex start-family hooks, and LaunchAgent `com.debrief.tts`. Bootstrap is `enable`, `bootout`, `bootstrap`, with one retry. Owned-file digests prevent uninstall from removing a binary whose contents differ from the manifest.

`debrief start` bootstraps the existing plist and does not rewrite it. A live pid prints `이미 실행 중입니다.` and does not bootout. `debrief stop` disables and bootouts the job, keeps the plist and the binary, and prints `서비스를 중지했습니다.` `debrief daemon` parks until SIGTERM or SIGINT. A second live daemon exits 0. A missing model records `last-error.json`, skips the socket, and stays running so KeepAlive does not spin.

Synthesis/playback failures and queue rejections write `~/Library/Caches/debrief/last-error.json`. `debrief doctor` prints them.

## Build and verification

```sh
cargo test --workspace
cargo clippy --workspace --all-targets
cargo build --release
```

GitHub Actions (`.github/workflows/ci.yml`) runs `cargo test --workspace`, `cargo clippy -- -D warnings`, and `cargo build --release --target aarch64-apple-darwin` on `macos-15`, then checks that the binary is arm64. A tag push matching `v*` triggers `.github/workflows/release.yml`, which builds the same release binary, packages it as a tarball, and publishes a GitHub Release.

The repository is [github.com/sparktype/debrief](https://github.com/sparktype/debrief). `DebriefVersion::CURRENT` is `0.1.1` (reads the workspace `Cargo.toml` version via `env!("CARGO_PKG_VERSION")`), tag `v0.1.1`. The tap formula is `sparktype/tap/debrief` (`class Debrief`, installs a prebuilt release tarball — no source build or Rust toolchain required on the user's machine). Install with `brew install sparktype/tap/debrief`, then `debrief install`. `Formula/chorus.rb` remains on the tap for tag `v0.0.1` and builds the previous `chorus` binary.

Release verification should also inspect architecture (`arm64`) and run install + offline speech smoke tests from a clean temporary home when models are available (`DEBRIEF_TEST_MODEL_DIR` for the real-model smoke test, gated the same way the Swift test suite gated it).

## Change rules

- Add a focused failing test before behavior changes.
- Run impact analysis before editing an existing symbol (`graft`/GitNexus when available).
- Keep the hook set exact (start-family only on Claude/Codex). Skills are `setup` + `install` + `speak` (Grok via `grok_skills`). MCP tools are `speak` + `install`.
- Do not persist hook payload text or synthesized audio.
- Preserve unrelated host settings and modified installed files.
- Do not reintroduce Python, Node, HTTP TTS servers, STT, or HTML speech envelopes.
- Run `cargo test --workspace`, `cargo clippy --workspace --all-targets`, and the release build before claiming completion.

## Active specs

| Spec | Topic |
| --- | --- |
| `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` | Single-binary Swift TTS (superseded by the Rust rewrite; envelope contract superseded earlier) |
| `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` | Earlier menu-bar process (superseded for packaging) |
| `docs/superpowers/specs/2026-09-29-daemon-single-binary-design.md` | Headless daemon and CLI controls (implemented; body still says chorus) |
| `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` | MCP speak + install + Grok (see errata for product truth) |
| `docs/superpowers/specs/2026-07-22-reflective-companion-design.md` | Lane, emotion, 도우미 음성 (attitude/timing superseded 2026-09-29 by the turn briefing) |
| `docs/superpowers/specs/2026-09-30-rust-rewrite-design.md` | Rust rewrite: crate boundaries, synchronous concurrency model, native-tls pin, deployment pipeline |

Older material lives under `docs/archive/` and is not product truth.
