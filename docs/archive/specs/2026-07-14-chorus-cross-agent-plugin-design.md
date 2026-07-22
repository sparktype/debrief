# Chorus Cross-Agent Plugin Design

**Date:** 2026-07-14
**Status:** Approved for implementation planning

## Objective

Make the plugin the primary Chorus installation and interaction surface for both Claude Code and Codex. A user should be able to install Chorus from either tool, complete one guided setup, use the same `/chorus:*` commands, and diagnose failures without inspecting JSON files or hidden logs.

## Success Criteria

- One shared plugin package serves Claude Code and Codex.
- Plugin installation never depends on the repository checkout path.
- Automatic speech and external LLM transmission remain disabled until guided setup records a privacy preset.
- Claude and Codex expose the same setup, status, mute, listen, mode, digest, and doctor workflows.
- Hook delivery is fast, fail-open, and leaves a user-visible diagnostic record when the local daemon is unavailable.
- Updating a plugin does not invalidate the LaunchAgent runtime path or erase user configuration and usage data.
- Legacy installation commands remain functional as compatibility wrappers during migration.
- Plugin manifests, hook contracts, runtime installation, migration, and privacy defaults are covered by automated tests.

## Product Boundaries

This change includes plugin packaging, marketplace metadata, hook delivery, runtime installation, platform event normalization, first-run privacy configuration, shared skills, diagnostics, documentation, and legacy migration.

This change does not add Windows or Linux runtime support. The TTS runtime remains macOS Apple Silicon only. It does not replace Supertonic, Whisper, or the configured summary provider, and it does not add a new external dependency solely for installation or event transport.

## Package Architecture

The repository will contain one shared package:

```text
plugins/chorus/
├── .claude-plugin/plugin.json
├── .codex-plugin/plugin.json
├── hooks/hooks.json
├── skills/
│   ├── setup/SKILL.md
│   ├── status/SKILL.md
│   ├── doctor/SKILL.md
│   ├── mute/SKILL.md
│   ├── listen/SKILL.md
│   ├── mode/SKILL.md
│   └── digest/SKILL.md
├── scripts/
│   ├── chorus-hook
│   └── chorus-runtime
├── runtime/
│   ├── hook_voice/
│   ├── tts_server/
│   └── assets/
└── assets/
```

The Claude and Codex manifests contain only ecosystem-specific metadata. Skills, hooks, runtime source, scripts, and assets are shared. Hooks use `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`; Codex provides those variables for plugin compatibility in addition to its native `PLUGIN_ROOT` and `PLUGIN_DATA` variables.

The Codex manifest remains valid under the installed `plugin-creator` validator. Because Codex discovers `hooks/hooks.json` by default, the Codex manifest does not need a `hooks` field. The Claude manifest declares or discovers the same default hook path and is validated with `claude plugin validate --strict` when that CLI is available.

## Marketplace Distribution

The repository provides both marketplace entry points:

- `.agents/plugins/marketplace.json` for Codex and ChatGPT desktop plugin discovery.
- `.claude-plugin/marketplace.json` for Claude Code plugin discovery.

Both entries point to `plugins/chorus` and use the stable plugin name `chorus`. Marketplace metadata describes local speech, optional external summarization, microphone access for STT, and macOS Apple Silicon requirements before installation.

The plugin is installed enabled so its setup skill is available, but its default runtime configuration is inert: `configured=false`, `autoSpeak=false`, `usageTracking=false`, and external LLM features disabled. Hooks exit successfully without network or speech side effects until setup completes.

## Runtime and Data Layout

Plugin cache paths are versioned and may change after updates, so LaunchAgent must not execute code directly from the plugin cache. Guided setup installs a runtime snapshot under:

```text
~/.local/share/chorus/
├── runtime/
│   ├── releases/<version>/
│   └── current -> releases/<version>
├── config.json
├── state.json
├── hud.json
├── usage_stats.jsonl
├── dlq.sqlite3
└── logs/
```

Runtime installation stages a new release, verifies its Python imports and hook entrypoint, then atomically switches `current`. A failed update leaves the previous `current` target active. Configuration, state, statistics, and logs live outside release directories and survive upgrades.

The single LaunchAgent label is `io.chorus.server`. Legacy `com.voice-persona.tts-server` registration is detected and removed only after the new runtime passes its health check. The service listens on loopback only.

## Hook Delivery

`hooks/hooks.json` registers the common events supported by both tools:

- `Stop`
- `SubagentStop`
- `PreToolUse` for Bash
- `PostToolUse` for Bash
- `UserPromptSubmit`
- `SessionStart`

Claude-only events such as `Notification` may be registered in a Claude-specific supplemental hook file when they have no Codex equivalent. The shared behavior must not claim parity for events that Codex cannot intercept.

The `chorus-hook` entrypoint performs only bounded work:

1. Read the JSON event from stdin.
2. Determine the runtime data directory from plugin environment variables or the stable user data default.
3. POST the raw event and source metadata to the loopback daemon with a short timeout.
4. Record the last delivery failure atomically when the daemon is unavailable.
5. Exit zero so speech failures never block the coding agent.

It must not start Python, load models, call an LLM, or detach an unobservable `nohup` process. Codex hook trust remains a product requirement; `/chorus:status` and `/chorus:doctor` explain `/hooks` review when the plugin hook has not executed successfully.

## Canonical Event Adapter

The daemon converts provider payloads into a stable internal event:

```python
@dataclass(frozen=True)
class HookEvent:
    source: Literal["claude", "codex", "opencode", "unknown"]
    event_name: str
    session_id: str
    cwd: Path | None
    transcript_path: Path | None
    turn_id: str | None
    agent_id: str | None
    agent_type: str | None
    assistant_message: str | None
    tool_name: str | None
    tool_input: Mapping[str, object]
    tool_response: Mapping[str, object]
    raw: Mapping[str, object]
```

Payload values take precedence over environment variables. Claude-specific environment variables and transcript locations are compatibility fallbacks only. Provider adapters own schema differences; speech policy and handlers consume only `HookEvent`.

## Guided Setup and Privacy

`/chorus:setup` is the required first-run path. It checks platform support, installs the runtime, registers the LaunchAgent, confirms hook availability, asks for a privacy preset, performs a voice test, and reports the final status.

Presets are explicit:

| Preset | Automatic speech | External LLM | Usage tracking | Tool-event speech |
| --- | --- | --- | --- | --- |
| `local` | On after voice test | Off | Off | Failures only, rule based |
| `standard` | On after voice test | Stop summaries only | Off | Failures only |
| `detailed` | On after voice test | Summaries, failure explanations, prompt advice | On | Build, test, risk, and failure events |

Before a preset is selected, all four capabilities are off. Setup displays which data leaves the machine and the configured endpoint before saving `standard` or `detailed`. Existing `.voice.json` values are imported once and the migration result is shown; migration never silently enables a capability that was disabled in the legacy file.

## Shared User Workflows

Both ecosystems package the same skills and command names:

- `/chorus:setup`: guided install, migration, privacy preset, and voice test.
- `/chorus:status`: concise runtime, hook, privacy, queue, and last-error status.
- `/chorus:doctor`: complete diagnostics and a bounded end-to-end smoke event.
- `/chorus:mute`: global, session, or 30-minute mute controls.
- `/chorus:listen`: STT toggle with actionable disabled, permission, and server errors.
- `/chorus:mode`: `normal`, `focus`, `quiet`, `verbose`, and `night` presets.
- `/chorus:digest`: recent event and speech summary.

Skill bodies call the stable `chorus-runtime` management interface rather than repository-relative `.venv/bin/python` paths. Text and behavior remain identical across Claude and Codex except where a tool-specific trust or capability message is necessary.

## Diagnostics and Recovery

Status is fast and read-only. It reports:

- setup completion and active privacy preset;
- runtime release and LaunchAgent state;
- daemon and model health;
- hook registration and last successful delivery per source;
- Codex trust guidance when no trusted execution is observed;
- queue depth, mute state, and last delivery/runtime error;
- data paths and whether usage tracking or external LLM transmission is enabled.

Doctor adds dependency imports, directory permissions, duplicate service detection, manifest validation availability, a synthetic Stop event, queue verification, and optional audible playback. Every failure includes one exact recovery command. Diagnostics do not send source text to an external LLM.

## Legacy Migration

`setup-tts.sh`, `server.sh install`, and `install.sh` remain executable during the migration release. They print a deprecation notice and delegate to the same runtime installer or tool-specific plugin installation guidance. Existing service-control commands continue to operate on `io.chorus.server`.

Hard-coded repository paths are removed from every legacy hook. Existing user hook entries that point to this repository are detected by migration and removed only after plugin hook delivery is verified. Uninstall removes plugin/runtime registrations but preserves user data by default; an explicit purge option removes configuration, statistics, models, and logs.

## Error Handling

- Hooks always fail open and never delay the agent beyond their delivery timeout.
- State and configuration writes use temporary files plus atomic replacement.
- Runtime upgrades stage and validate before switching releases.
- Marketplace or manifest validation failure blocks packaging, not local coding-agent operation.
- Missing optional LLM credentials degrade to local rule-based summaries.
- Missing STT dependencies disable only `/chorus:listen` and explain the repair.
- A data-directory write failure is visible in status and cannot recursively write to the same failing store.

## Testing Strategy

Tests run with an isolated temporary HOME and no external network, microphone, audio device, or live coding-agent process.

Required suites:

1. Manifest and marketplace schema validation for Claude and Codex.
2. Hook runner tests for movable plugin paths, unavailable daemon, timeout, atomic failure state, and fail-open exit status.
3. Claude and Codex payload fixtures for Stop, SubagentStop, PreToolUse, PostToolUse, UserPromptSubmit, and SessionStart.
4. Runtime installer tests for first install, idempotent reinstall, staged update, rollback, duplicate legacy LaunchAgent migration, and preserved data.
5. Privacy tests proving the unconfigured state performs no external LLM call, statistics write, or speech.
6. Skill parity tests ensuring both manifests expose the same seven `/chorus:*` workflows.
7. Doctor tests for actionable failure messages and synthetic event delivery.
8. Existing unit tests, followed by the complete suite in the locked dependency environment.

## Compatibility and Rollout

The first plugin release retains `.voice.json` import and legacy CLI wrappers. Documentation presents plugin installation first and labels the repository-script path as legacy. The following release may remove direct hook registration only after migration telemetry or user reports show that plugin installation is stable; removing legacy support is not part of this implementation.

## Acceptance Checklist

- A fresh Claude user can install, run `/chorus:setup`, choose `local`, and hear the voice test without editing JSON.
- A fresh Codex user receives clear `/hooks` trust guidance and can verify delivery through `/chorus:status`.
- Moving or deleting the source checkout after runtime setup does not break speech.
- Reinstalling or updating the plugin keeps configuration and uses one LaunchAgent.
- An unconfigured plugin produces no speech, statistics, or external LLM traffic.
- Claude and Codex present the same seven Chorus skills.
- An offline daemon never blocks a coding-agent turn and leaves a visible last-error record.
- Legacy commands delegate successfully and no committed hook contains a developer-specific absolute path.
