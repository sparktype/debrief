# Chorus Swift Single-Binary TTS Design

**Date:** 2026-07-15

**Status:** Approved

**Target:** macOS on Apple Silicon

This design supersedes the active Python TTS/STT server, Chorus-side LLM summarization, observability, and MCP runtime designs.

## 1. Outcome

Chorus becomes a TTS-only macOS service distributed as one Swift executable named `chorus`.

Codex and Claude produce a short spoken summary plus its voice, speed, and volume. Chorus validates that request, synthesizes it locally with Supertonic, and plays it. Chorus does not summarize, rewrite, classify, or otherwise interpret an agent response.

The executable also installs and manages the hooks and skills required by Codex and Claude. Supertonic models and voice profiles are external data downloaded during initial installation.

## 2. Scope

In scope:

- One Swift executable containing the CLI, installer, hook adapter, daemon, queue, Supertonic adapter, and audio player
- Supertonic 3 through the official Swift ONNX Runtime path
- Codex and Claude hooks and skills
- Agent-generated speech envelopes and agent-specific voices
- Initial model download with integrity verification
- Unix domain socket transport and LaunchAgent lifecycle
- TTS modes, mute, status, diagnostics, and legacy preference migration

Removed:

- STT, microphone access, Whisper, and `listen`
- Chorus-side LLM clients, summarization, briefing, recommendation, and speech retouching
- Transcript parsing, last-message recovery, and whole-response fallback
- Python and Node runtimes, FastAPI, and the local HTTP API
- MCP servers and `node_repl` integration
- Structured logs, correlation IDs, metrics, Prometheus, history, digest, DLQ, usage tracking, circuit breakers, and advisors
- PreToolUse and PostToolUse hooks

Deferred:

- A native MLX port of Supertonic
- GPU inference
- Cross-platform and remote API support

MLX Swift is not used in this release. Supertonic provides a maintained Swift ONNX example, while an MLX implementation would require a separate conversion and quality-validation track. The one-executable goal takes priority.

## 3. Distribution Contract

The shipped runtime code is one Apple Silicon executable:

```text
~/.local/bin/chorus
```

External data is stored separately:

```text
~/Library/Application Support/Chorus/
  config.json
  install-manifest.json
  models/supertonic-3/<revision>/
  voices/

~/Library/Caches/Chorus/
  chorus.sock
  daemon-state.json
  last-error.json

~/Library/LaunchAgents/com.chorus.tts.plist
```

Generated hooks, skills, configuration, models, and the LaunchAgent plist are data rather than additional runtime programs. Hook commands invoke `chorus` directly without Python, Node, or shell wrappers.

The ONNX Runtime Swift package is linked as a static library. Release validation must prove that the executable has no non-system dynamic library dependencies.

## 4. CLI Surface

```text
chorus install [--codex] [--claude] [--repair]
chorus uninstall [--codex] [--claude]
chorus daemon
chorus hook --source <codex|claude>
chorus speak --text <text> --voice <id> --speed <value> --volume <value>
chorus status
chorus mute [on|off|toggle]
chorus mode [normal|focus|quiet|verbose|night]
chorus doctor
```

`chorus install` without host flags detects installed hosts and configures both when available. Repeated installation is idempotent.

## 5. Process Architecture

```text
Codex / Claude
      │ lifecycle hook JSON on stdin
      ▼
chorus hook --source <host>
      │ strict speech-envelope extraction
      ▼
user-only Unix domain socket
      │
chorus daemon
      ├── resident Supertonic ONNX sessions
      ├── voice profile cache
      ├── bounded priority queue
      └── AVAudioEngine playback
```

The daemon owns model initialization and audio playback. Hook processes validate input, submit a request, receive an acknowledgement, and exit without waiting for synthesis or playback. The socket and its parent directory are accessible only to the current user. Chorus opens no TCP port or HTTP server.

## 6. Speech Envelope

Codex and Claude append exactly one single-line HTML comment to the final response:

```html
<!-- chorus:speak {"v":1,"text":"Swift 기반 TTS 설계를 완료했습니다.","voice":"F1","speed":0.93,"volume":0.85} -->
```

All fields are required:

| Field | Type | Contract |
| --- | --- | --- |
| `v` | integer | Must equal `1` |
| `text` | string | Non-empty spoken summary, at most 800 user-perceived characters |
| `voice` | string | Installed voice ID from the allowlist |
| `speed` | number | `0.7...2.0` |
| `volume` | number | `0.0...1.0` requested playback gain |

The parser reads only `last_assistant_message` and selects the last valid envelope. It never reads a transcript. Unknown keys, unsupported versions, missing fields, invalid numbers, control characters, non-allowlisted voices, or malformed JSON make the envelope invalid. An invalid or absent envelope produces no speech.

Spoken text should normally be one or two natural sentences without Markdown, raw code, long paths, logs, or another HTML comment terminator.

Implementation must first validate that current Codex and Claude versions preserve the comment in `last_assistant_message`. No transcript fallback is introduced if a host changes this behavior.

## 7. Agent Voice Rules

The agent, not Chorus, creates `text` and emits `voice`, `speed`, and `volume`. Hooks inject the relevant contract and assignment.

| Category | Voice | Name | Baseline speed |
| --- | --- | --- | --- |
| reviewer | `M2` | 빌 | `0.92` |
| planner | `M1` | 스티브 | `1.10` |
| builder | `M4` | 리누스 | `0.95` |
| tester | `F2` | 마리 | `1.10` |
| explorer | `F3` | 제인 | `1.00` |
| optimizer | `M3` | 일론 | `1.00` |
| guardian | `M5` | 팀 | `0.88` |
| ops | `F4` | 셰릴 | `1.05` |
| specialist | `F5` | 리사 | `0.88` |
| default and main | `F1` | 연아 | `0.93` |

The injected instruction tells each agent its category, voice, and baseline speed. The agent may choose another valid speed for the content but must retain its assigned voice. It selects a requested volume appropriate to the response. Local mute and mode-specific volume caps remain authoritative.

Unknown agent types use `F1`. Arbitrary voice profile paths are never accepted.

## 8. Hook Set

Only five hooks are installed:

| Event | Responsibility |
| --- | --- |
| `SessionStart` | Inject the durable contract and main-agent defaults |
| `UserPromptSubmit` | Reinject a compact reminder for turn and compaction resilience |
| `SubagentStart` | Inject the subagent category, voice, speed, and contract |
| `Stop` | Extract and enqueue a valid main envelope |
| `SubagentStop` | Extract and enqueue a valid subagent envelope |

`chorus hook --source` adapts the different Codex and Claude schemas to one internal event and emits the exact success or context JSON required by the selected host.

Stop hooks never ask an agent to continue because speech failed. Delivery failure is a Chorus concern, not an agent completion condition.

## 9. Daemon and Queue

The daemon initializes Supertonic sessions, voice profiles, the serial synthesis queue, AVAudioEngine, and the socket once.

Queue rules:

- Synthesis and playback are serialized.
- Main `Stop` requests outrank `SubagentStop` requests.
- A new main request removes stale queued subagent requests.
- Duplicate envelopes received in a short window are spoken once.
- Capacity is eight requests.
- An active main request is not interrupted.
- An active subagent request may be interrupted by a new main request.
- Long text is split at sentence boundaries to reduce time to first audio.
- Queue history is not persisted.

## 10. Mode Policy

The agent always supplies volume. Local policy can only reduce or suppress it.

| Mode | Eligible events | Effect |
| --- | --- | --- |
| `normal` | Main and subagent | Standard configured volume ceiling |
| `focus` | Main only | Suppress subagents |
| `quiet` | Main only | Reduced volume ceiling |
| `verbose` | Main and all subagents | Standard volume ceiling |
| `night` | Main only | Lowest volume ceiling |
| mute | None | Discard all requests |

Modes do not replace agent-selected voice or speed.

## 11. Model Installation

The executable embeds a versioned manifest with immutable source URLs, model revision, relative paths, sizes, and SHA-256 digests.

Installation:

1. Detect a complete matching revision.
2. Download missing assets with `URLSession` into staging.
3. Verify every file and digest.
4. Atomically activate the complete directory.
5. Preserve the previous valid revision until activation succeeds.
6. Start or restart the daemon only after validation.

No `curl`, Git LFS, Homebrew, Python, or Node is required. `--repair` fetches only missing or invalid assets. Synthesis works offline after installation.

## 12. Hook and Skill Installation

Embedded versioned templates are installed to the host's user configuration:

- Codex skills: `~/.agents/skills/chorus-*`
- Claude skills: `~/.claude/skills/chorus-*`
- Codex hooks: merged into the active user hook configuration
- Claude hooks: merged into the active user settings

TTS-only skills:

- setup
- status
- mode
- mute
- speak
- doctor

The installer never replaces an entire host settings file. It backs up before modification, uses atomic writes, records exact owned entries and digests, avoids duplicates, removes only unchanged Chorus-owned content, and warns instead of deleting user-modified installed files.

Codex hook trust is not bypassed. Installation reports the official review step for new or changed hooks.

No MCP server is installed. A legacy MCP or `node_repl` entry is removed only when it exactly matches a known Chorus-owned entry; unrelated MCP configuration is preserved.

## 13. Errors Without Observability

Hook behavior:

- Missing or invalid envelope: succeed without speech.
- Socket failure: one bounded retry, then succeed.
- Host schema mismatch: return the host's safe success output and record the current error.

Daemon behavior:

- Missing or corrupt model: reject synthesis and direct `doctor` to repair it.
- Synthesis failure: discard that request and continue.
- Audio device change: rebuild the audio engine once.
- Direct CLI failure: explain on stderr and return nonzero.

The only retained diagnostic data is current process/socket/model state and one atomically overwritten `last-error.json`. It contains no transcript, spoken-text history, metrics series, correlation IDs, or usage data.

## 14. Migration and Deletion

The first Swift installation migrates only:

- mute or auto-speak state;
- selected mode;
- category voice assignments;
- per-voice baseline speed; and
- user volume limits.

It does not migrate LLM credentials, transcript settings, metrics, history, STT, or HTTP configuration. The new daemon must pass model and health checks before known legacy Python LaunchAgents are unloaded.

After the Swift path is verified, remove:

- `hook_voice/`;
- `tts_server/` and its supervisor;
- the duplicated Python plugin runtime payload;
- Python and shell runtime wrappers and obsolete hook scripts;
- Python requirements, pytest configuration, and legacy installers;
- tests that exist only for removed behavior; and
- active docs and manifests advertising removed features.

Historical design documents remain as history. This document is the current source of truth.

## 15. Tests

Unit coverage:

- Strict envelope parsing, escaping, selection, and rejection
- Required fields, ranges, character limits, and voice allowlist
- Agent type to category, voice, and baseline speed
- Mode eligibility and volume ceilings
- Queue priority, interruption, capacity, and deduplication
- Settings merge, reinstall, uninstall, and user-edit preservation
- Model manifest, digest, staging, and atomic activation

Integration coverage:

- Codex and Claude fixtures for all five hooks
- Exact host-specific hook stdout
- Socket protocol and `0600` access
- Queue and audio flow with a deterministic fake backend
- Interrupted and corrupt downloads through a local test server
- Legacy settings migration and LaunchAgent lifecycle

Release checks:

```bash
swift test
swift build -c release
file .build/release/chorus
otool -L .build/release/chorus
```

Model-backed smoke tests synthesize and play Korean through every bundled voice, then repeat with networking disabled. Host smoke tests verify that both hosts preserve the envelope and enqueue it without delaying turn completion.

## 16. Completion Criteria

- `chorus` is an Apple Silicon executable.
- ONNX Runtime is static and `otool -L` shows no non-system runtime dependency.
- Hooks invoke no Python, Node, or shell wrapper.
- Codex and Claude receive the five hooks and six TTS-only skills.
- Every spoken request comes from a valid agent-authored envelope with required text, voice, speed, and volume.
- Agent-specific voices match the approved mapping.
- Chorus makes no LLM call and inspects no transcript.
- Pinned Supertonic assets install with integrity checks and work offline.
- Korean model-backed speech passes.
- Install, repair, reinstall, and uninstall preserve unrelated user settings.
- The active runtime contains no STT, HTTP server, MCP, Python TTS, observability, history, digest, or usage tracking.
- The only distributed runtime code is `chorus`; models, settings, hooks, skills, and LaunchAgent are external data.

## 17. Primary Risks and Gates

1. Validate HTML comment preservation on current Codex and Claude before building the hook path.
2. Prove static ONNX Runtime packaging with `otool -L` in release validation.
3. Pin the Supertonic model revision used by Swift and reject partial upgrades.
4. Test ownership-aware installation against representative existing host settings.
5. Benchmark cold start, warm time to first audio, memory, and chunking on Apple Silicon without adding product telemetry.

## 18. References

- [Supertonic](https://github.com/supertone-inc/supertonic)
- [Supertonic Swift example](https://github.com/supertone-inc/supertonic/tree/main/swift)
- [ONNX Runtime Swift package](https://github.com/microsoft/onnxruntime-swift-package-manager)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- [Codex hooks](https://developers.openai.com/codex/hooks)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
