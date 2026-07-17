# Chorus MenuBar Resident TTS Design

**Date:** 2026-07-17

**Status:** Approved

**Target:** macOS 14+ Apple Silicon

**Supersedes (process model only):** headless LaunchAgent `chorus daemon` as the sole resident path in `2026-07-15-swift-single-binary-tts-design.md`. Speech envelope, hooks, modes, model install, and TTS-only product boundary remain in force.

## 1. Outcome

Chorus remains one product and one shipped executable named `chorus`.

The resident process becomes an LSUIElement menu bar app that hosts the TTS daemon **in-process**. Users control service start/stop, mute, and mode from the menu bar. CLI subcommands (`hook`, `speak`, `install`, `status`, `mute`, `mode`, `doctor`, …) stay on the same binary.

SPM keeps `ChorusCore` as a library for tests and domain logic. `ChorusCLI` is the single product entry target. Targets are **not** merged into one SPM module; integration is at the product and process level.

## 2. Scope

In scope:

- Menu bar (LSUIElement / activation policy `.accessory`) as the normal resident process
- In-process daemon: Unix domain socket, Supertonic sessions, speech queue, audio playback
- LaunchAgent starts `chorus menubar` instead of `chorus daemon`
- Menu actions: status display, mute, mode, service start/stop
- Core `ResidentService` (or equivalent) extracted from the current daemon entry path
- Status/doctor wording and LaunchAgent template updates
- Compatibility: `chorus daemon` remains a headless in-process path for debug/fallback

Out of scope:

- Merging `ChorusCore` and `ChorusCLI` into a single SPM target
- Shipping as a `.app` bundle under `/Applications`
- Preferences window, Dock icon, notification center
- Quit menu that fights LaunchAgent KeepAlive
- Disabling LaunchAgent from the menu bar
- Changing hook envelope, host set, or TTS-only product boundary
- Python/Node runtime or second shipped binary

## 3. Decisions

| Topic | Decision |
| --- | --- |
| Product surface | Single `chorus` executable |
| SPM layout | Keep `ChorusCore` + `ChorusCLI` |
| Resident host | Menu bar process (LSUIElement) |
| Where daemon runs | Inside the menu bar process |
| LaunchAgent | Label `com.chorus.tts` kept; args become `menubar` |
| KeepAlive | `true` (crash/exit relaunches menu bar) |
| Menu Stop | Stops in-process TTS service only; menu bar stays up |
| Menu Quit | **Hidden** in v1; full off via `uninstall` / launchctl |
| CLI `daemon` | Kept for headless debug; not the install path |

## 4. Process Architecture

```text
Login / chorus install
        │
        ▼
LaunchAgent (com.chorus.tts)
        │ ProgramArguments: [<bin>/chorus, "menubar"]
        ▼
chorus (LSUIElement)
        ├── MenuBarExtra UI
        │     status · mute · mode · start · stop
        └── ResidentService (in-process)
              ├── pid file
              ├── Unix socket server
              ├── ChorusDaemon + SpeechQueue
              ├── SupertonicEngine
              └── AudioPlayer

Codex / Claude ──► chorus hook ──► socket ──► ResidentService
CLI              ──► chorus speak|status|mute|mode|…
```

### Entry modes

| Invocation | Behavior |
| --- | --- |
| `chorus menubar` | `NSApplication` + MenuBarExtra, policy `.accessory`, start `ResidentService` |
| no arguments | Print usage/help (unchanged CLI default). LaunchAgent always passes `menubar` explicitly. |
| `chorus daemon` | Headless resident service only (no menu bar UI); debug/fallback |
| other subcommands | Existing headless CLI; do not start AppKit menu bar |

### Single-instance rule

On resident start (`menubar` or `daemon`):

1. If an owned live PID and healthy socket already represent a running resident, the new process exits without taking over (prefer fail-closed bind / pid check).
2. Stale PID or socket is cleaned using the same safety rules as today’s socket setup.
3. Only one process may bind `chorus.sock`.

## 5. Module Layout

```text
Package.swift
  product: executable "chorus" → ChorusCLI
  targets:
    ChorusCore          // domain, daemon, install, diagnostics, ResidentService
    ChorusCLI           // argument parse, CLI handlers, SwiftUI/AppKit menu bar
    ChorusCoreTests
    ChorusIntegrationTests
```

**Integration meaning:** one product UX and one resident process model. Not a forced single SPM target.

### Core responsibilities

- Existing: envelope, hooks, queue, TTS, config, install, diagnostics, socket
- New: `ResidentService` lifecycle (`start` / `stop` / `isRunning` / status inputs)
- Config read path unchanged: request-time load from `config.json` remains valid

### CLI responsibilities

- Parse including `menubar`
- Menu bar view + actions calling Core / configuration commands
- Existing command handlers; daemon body becomes thin wrapper over `ResidentService`

AppKit/SwiftUI stay out of `ChorusCore` so tests remain non-UI.

## 6. LaunchAgent and Install Contract

### LaunchAgent template

```text
Label: com.chorus.tts
ProgramArguments: [<executable.path>, "menubar"]
RunAtLoad: true
KeepAlive: true
```

- Domain remains `gui/<uid>`
- Install still: write plist → `bootout` → `bootstrap`
- Repair overwrites owned plist when digest matches owned path policy (same as today)

### Paths (unchanged)

```text
~/.local/bin/chorus
~/Library/Application Support/Chorus/
~/Library/Caches/Chorus/   (socket, pid, last-error)
~/Library/LaunchAgents/com.chorus.tts.plist
```

### Migration

1. `install` / `install --repair` writes the menubar LaunchAgent.
2. Existing agents still running headless `daemon` are replaced by bootout/bootstrap.
3. No migration of models, config, or host hooks beyond normal install ownership rules.
4. Skills/docs/doctor recovery text refer to the menu bar resident where relevant; recovery command remains `chorus install --repair` when the agent is broken.

### Uninstall

Unchanged semantics: bootout LaunchAgent, remove owned runtime files, preserve user-modified files.

## 7. CLI Surface

```text
chorus install [--codex] [--claude] [--repair]
chorus uninstall [--codex] [--claude]
chorus menubar
chorus daemon
chorus hook --source <codex|claude>
chorus speak --text <text> --voice <id> --speed <value> --volume <value>
chorus status
chorus mute [on|off|toggle]
chorus mode [normal|focus|quiet|verbose|night]
chorus doctor
```

- `menubar` is the supported resident entry for LaunchAgent.
- `daemon` remains for developers and emergency headless runs; not written into the installed LaunchAgent after this change.

## 8. Menu Bar Control Surface (v1)

| Item | Behavior |
| --- | --- |
| Status header (disabled) | Short summary: running/stopped, muted, mode |
| Mute / Unmute | Toggle or set via existing configuration save |
| Mode submenu | `normal`, `focus`, `quiet`, `verbose`, `night` |
| Start service | `ResidentService.start()`; no-op if already running |
| Stop service | `ResidentService.stop()`; closes socket, shuts queue/audio; **menu bar process remains** |
| Quit | **Not shown** in v1 |

Full disable of auto-start remains `chorus uninstall` or manual `launchctl bootout gui/$UID/com.chorus.tts`.

Mute/mode from the menu bar use the same `config.json` path as CLI so hooks and menu stay consistent.

## 9. ResidentService API (conceptual)

```text
ResidentService
  start() async throws
  stop() async
  isRunning: Bool
```

`start()` owns:

1. Ensure directories and permissions
2. Write pid file
3. Open `UnixSocketServer`
4. Resolve current model revision; fail start if invalid
5. Construct `ChorusDaemon` with Supertonic backend and audio player
6. Run accept loop until stop/shutdown

`stop()` owns:

1. Signal daemon shutdown
2. Close socket / remove safe socket path
3. Clear pid if owned
4. Leave process alive when called from menu bar Stop

`chorus daemon` and `chorus menubar` both drive this service; only menubar attaches UI.

## 10. Status and Diagnostics

Keep `StatusSnapshot` fields; clarify meaning:

- `process`: resident process (menu bar or headless daemon) pid state
- Do **not** require a new `residentMode` field in v1. Document `process` as the generic resident (menu bar or headless daemon).

Doctor findings continue to point at `chorus install --repair` for stale/missing resident, missing socket, or missing LaunchAgent.

## 11. Errors

| Case | Behavior |
| --- | --- |
| Model missing/invalid | Start fails; menu shows error; doctor recommends repair |
| Socket bind failure / instance already running | New instance exits; existing resident unchanged |
| Synthesis failure | Drop request in memory; service continues (unchanged) |
| CLI mute/mode without resident | Config write still succeeds (unchanged) |
| Hook when service stopped | Submit fails; hook success-without-speech or host-required response rules unchanged |

No new observability stack. Bounded `last-error.json` may record resident start failures.

## 12. Testing

TDD: failing tests before behavior changes.

- Core: `ResidentService` start/stop; stop removes socket; double-start rejected or second fails cleanly
- Templates: LaunchAgent `ProgramArguments` ends with `menubar`
- CLI parse: `menubar` accepted; usage text updated
- Integration: headless `daemon` path still starts socket and accepts a speak/submit when models available in fixtures
- Config: mute/mode from configuration APIs still affect admit policy
- UI logic: if actions are factored behind a small non-View type, unit-test mute/mode/start/stop calls; full AppKit UI smoke optional

Toolchain: Xcode 27 beta via `./scripts/with-xcode.sh swift test` and release build.

## 13. Implementation Order (for the plan)

1. Extract `ResidentService` from CLI daemon entry; cover with tests; wire `daemon` through it
2. Add `menubar` command parse + LaunchAgent template change + installer tests
3. Add menu bar UI and wire Start/Stop/Mute/Mode
4. Update README / DEVELOPER / skills status wording as needed for resident model
5. Full test suite + release build

## 14. Non-Goals Recap

Do not reintroduce Python, HTTP, STT, Chorus-side LLM summarization, or a second shipped runtime binary. Do not replace agent speech envelopes with menu-bar-composed speech for hooks.

## 15. Success Criteria

- Installed LaunchAgent starts menu bar resident with working TTS socket
- Menu can mute, change mode, stop service (no speech), start service (speech resumes)
- Hooks and `chorus speak` continue to use the same socket contract
- One user-facing executable: `chorus`
- `swift test` and release build green under Xcode 27 beta
- No Quit menu; KeepAlive behavior is not undermined by the UI
