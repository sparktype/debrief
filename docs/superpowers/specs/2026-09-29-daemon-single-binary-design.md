# Chorus Daemon Single-Binary Design

**Date:** 2026-09-29

**Status:** Pending review

**Target:** macOS 14+ Apple Silicon

**Supersedes (process model and packaging only):**

- The menu bar resident process in `2026-07-17-menubar-resident-tts-design.md`.
- The Chorus.app packaging that shipped after that spec: an LSUIElement bundle under `/Applications` or `~/Applications`, `AssociatedBundleIdentifiers` on the LaunchAgent, ad-hoc bundle signing, and the removal of the user CLI.
- The headless-daemon distribution path in `2026-07-15-swift-single-binary-tts-design.md` §3 is restored. That document's `chorus speak` CLI (§4) and HTML speech envelope (§6) stay retired.

**Remains in force:**

- MCP `speak` and `install`, including the product errata on `2026-07-19-mcp-speak-tool-design.md`.
- Reflective companion speech, lanes, and emotion (`2026-07-22-reflective-companion-design.md`).
- Per-host MCP wiring facts from `2026-07-22-menubar-mcp-status-design.md`. The menu that displayed them is removed. `chorus doctor` and `chorus status` report the same on-disk facts.
- TTS-only product boundary, start-family hooks, no Python or Node runtime, no second shipped executable.
- `ChorusCore` stays a library. `ChorusCLI` stays the only product target. The targets are not merged.

## 1. Outcome

Chorus ships as one Apple Silicon executable, `chorus`. `chorus install` copies that executable to `~/.local/bin/chorus`. LaunchAgent `com.chorus.tts` runs it as `chorus daemon` in the user GUI session. There is no Chorus.app and no menu bar.

Mute, mode, companion voice, status, diagnostics, and service start/stop are CLI commands on the same binary. Agents still speak only through MCP `speak`. The daemon reloads `config.json` on each utterance, so mute, mode, and companion changes apply on the next utterance without a restart.

## 2. Distribution

```text
~/.local/bin/chorus

~/Library/Application Support/Chorus/
  config.json
  install-manifest.json
  models/supertonic-3/<revision>/

~/Library/Caches/Chorus/
  chorus.sock
  daemon.pid
  last-error.json

~/Library/LaunchAgents/com.chorus.tts.plist
```

`ChorusPaths.executableURL` is `~/.local/bin/chorus`. The application-bundle URL and the legacy-symlink URL fields are removed. App cleanup uses the two fixed paths `/Applications/Chorus.app` and `~/Applications/Chorus.app`.

Models, config, the socket, the pid file, and `last-error.json` keep their current locations. Migration from `~/.local/share/chorus` stays best-effort and still must not fail an otherwise successful install.

The LaunchAgent plist contains:

| Key | Value |
| --- | --- |
| `Label` | `com.chorus.tts` |
| `ProgramArguments` | `[<absolute ~/.local/bin/chorus>, "daemon"]` |
| `RunAtLoad` | `true` |
| `KeepAlive` | `true` |

The plist has no `AssociatedBundleIdentifiers` and no shell wrapper. Bootstrap stays in the `gui/<uid>` domain. It is not loaded into a background-only session, so playback keeps using that session's audio device. The bootstrap sequence is unchanged: `enable` (failure allowed), `bootout` (failure allowed), `bootstrap`, and one retry after a second `bootout` if the first `bootstrap` fails.

## 3. Resident process

`chorus daemon` starts `ResidentService` on the main thread, then parks on the main run loop until a signal. It does not create an `NSStatusItem` or initialize an AppKit application.

`SIGTERM` and `SIGINT` stop the service, remove the socket and pid file, and exit 0.

When `ResidentService.start()` reports that another live pid already holds the daemon, this process prints `이미 실행 중입니다.` and exits 0. It does not open a second socket. Exit 0 is required so a `KeepAlive` relaunch does not spin.

When the model is missing or invalid, the process records the failure in `last-error.json`, does not open the socket, and does not exit. It waits for `SIGTERM` or `SIGINT`. `chorus install --repair` replaces the LaunchAgent process after the model is in place.

Speech submission is unchanged. MCP `speak` and hook processes validate, enqueue on the user-only Unix socket, and exit without waiting for synthesis or playback. Synthesis and transport failures are written to `last-error.json` and do not fail the agent turn.

## 4. CLI

```text
chorus install [--codex] [--claude] [--grok] [--repair]
chorus uninstall [--codex] [--claude] [--grok]
chorus daemon
chorus start
chorus stop
chorus status
chorus mute [on|off|toggle]
chorus mode [normal|focus|quiet|verbose|night]
chorus companion [on|off|toggle]
chorus doctor
chorus mcp
chorus hook --source <codex|claude>
chorus help
```

No arguments prints usage on stdout and exits 0. Unknown commands, including `menubar` and `speak`, and bad flags print usage on stderr and exit 64.

`daemon` is the long-running process LaunchAgent starts. A person may run it in the foreground when the agent is not already running. A second `daemon` hits the already-running rule in §3.

`start` enables the agent. If the LaunchAgent plist is absent, it prints `LaunchAgent가 없습니다. chorus install을 실행하세요.` and exits 1. It does not write a plist. If `Diagnostics` reports the daemon process as running, it prints `이미 실행 중입니다.` and exits 0 without bootout or kickstart. Otherwise it runs the same bootstrap sequence as install. On success it prints `서비스를 시작했습니다.`

`stop` disables the agent and bootouts the job so the next login does not start it. Bootout failure is ignored when the job is already unloaded. It does not delete the plist or the binary. It prints `서비스를 중지했습니다.` `chorus start` and `chorus install` both enable the agent again.

`mute`, `mode`, and `companion` only read and write `config.json` through the existing `ConfigurationCommands`. They do not restart the daemon. Invalid values are rejected before the file changes.

| Command | No argument | With argument | Printed result |
| --- | --- | --- | --- |
| `mute` | toggle | `on`, `off`, or `toggle` | `음소거했습니다.` or `음소거를 해제했습니다.` |
| `companion` | toggle | `on`, `off`, or `toggle` | `도우미 음성을 켰습니다.` or `도우미 음성을 껐습니다.` |
| `mode` | print only, no write | one `ChorusMode` raw value | no argument: `현재 모드는 <mode>입니다.` set: `모드를 <mode>로 설정했습니다.` |

`status` prints the following lines and exits 0 even when the daemon is down:

```text
프로세스: 실행 중 | 없음 | 오래된 pid | 잘못된 pid
음소거: 켜짐 | 꺼짐
모드: <ChorusMode raw value>
도우미 음성: 켜짐 | 꺼짐
모델: <revision> | <revision> (사용할 수 없음) | 없음
소켓: 있음 | 없음
LaunchAgent: 설치됨 | 없음
```

`음소거: 켜짐` means `muted == true`. A model revision with `modelValid == false` uses the `사용할 수 없음` form.

`doctor` prints the current `doctorReportText()` and exits 1 when any finding is not ok, otherwise 0. Recovery text no longer mentions the menu bar or `chorus menubar`. A running process with no socket is the parked daemon from §3, so `chorus start` would refuse to replace it.

The first matching row wins.

| Order | Condition | Recovery |
| --- | --- | --- |
| 1 | LaunchAgent plist is absent, or the model is missing or invalid | `chorus install --repair` |
| 2 | Process is running, and the socket is absent | `chorus install --repair` |
| 3 | Process is not running, and the LaunchAgent plist exists | `chorus start` |

A failed config save leaves the previous file in place, prints `설정을 저장하지 못했습니다.` plus the underlying reason on stderr, and exits 1. A failed `start` prints `서비스를 시작하지 못했습니다.` plus the reason, exits 1, and does not change `config.json`. A failed `stop` prints `서비스를 중지하지 못했습니다.` plus the reason, with the same exit and config rules. When `~/.local/bin/chorus` is a directory, install prints `실행 파일 경로가 디렉터리입니다. ~/.local/bin/chorus 를 비운 뒤 다시 설치하세요.` and exits 1.

## 5. Install, ownership, and Chorus.app removal

Install order:

1. Copy the source executable to `~/.local/bin/chorus`.
2. Install or repair the model.
3. Run `HostInstaller` with that executable URL so MCP commands and hooks are rewritten to it.
4. Write the LaunchAgent plist.
5. Record ownership digests for the executable and the plist.
6. Bootstrap the agent.
7. Only after bootstrap succeeds, remove leftover Chorus.app bundles.
8. Run the existing `~/.local/share/chorus` migration as best-effort.

The copy is the existing atomic replace: write a temporary file, `fsync`, then `rename` into place, mode `0755`. When the source and destination are the same file, the installer only sets that mode. When `~/.local/bin` is missing, the installer creates it. When `~/.local/bin/chorus` exists and is a directory, the installer fails without deleting it. The current unconditional deletion of that path is removed.

Chorus owns `~/.local/bin/chorus`. Uninstall removes it only when the on-disk digest matches `install-manifest.json`. A mismatch leaves the file and reports its path, which is the same rule as other owned files. Uninstall also bootouts the agent, removes the plist when its digest matches, and removes host wiring through the existing owned-file rules.

A Chorus.app is removed only when its `CFBundleIdentifier` is `com.chorus.tts`, and only from `/Applications/Chorus.app` or `~/Applications/Chorus.app`. Install removes those bundles after a successful bootstrap. Uninstall removes them as well, including bundles recorded by an older manifest. A failed bootstrap leaves any existing Chorus.app on disk. The in-progress bootstrap may already have unloaded the previous agent. The recovery command is `chorus install --repair`.

## 6. Code boundary

Remove:

- `Sources/ChorusCLI/MenuBarApp.swift`
- `Sources/ChorusCLI/MenuBarIcons.swift`
- `Sources/ChorusCLI/MenuBarModel.swift`
- `Sources/ChorusCore/AppBundleInstaller.swift`
- `Sources/ChorusCore/MenuBarMenuTitles.swift`
- `Sources/ChorusCore/MenuBarStatus.swift`
- `SwiftTests/ChorusCoreTests/AppBundleInstallerTests.swift`
- `SwiftTests/ChorusCoreTests/MenuBarMenuTitlesTests.swift`
- `SwiftTests/ChorusCoreTests/MenuBarStatusTests.swift`
- The AppKit import, `menubar` branch, and application-icon PNG loading in `EntryPoint`
- App-bundle install, icon ownership, and unconditional `~/.local/bin/chorus` deletion in `RuntimeInstaller`
- `Info.plist` generation, app-icon templates, and `AssociatedBundleIdentifiers` in `EmbeddedTemplates`
- The application-icon argument threaded through `McpInstallTool`

Keep:

- `ResidentService`, `ChorusDaemon`, the socket, the queue, Supertonic, and playback
- MCP `speak` and `install`, hooks, skills, and `HostInstaller`
- `ConfigurationCommands`, `Diagnostics`, `LaunchAgentControl`, and model install
- `DirectSpeechCommand` as an in-library submit API. It is not exposed as `chorus speak`
- Best-effort migration from `~/.local/share/chorus`

`ChorusCLI` no longer imports AppKit. Playback stays on the existing audio stack inside `ChorusCore`.

Every user-facing instruction that tells a person to change mute, mode, companion voice, diagnostics, start, or stop from the menu bar is rewritten to the CLI in §4. This includes hook context, embedded skills, checked-in skills under `.claude/skills/`, and doctor recovery lines. The agent speech contract itself is unchanged. Polite Korean stays the voice of user-visible strings.

Update these product documents to describe the daemon install: `README.md`, `ONBOARDING.md`, `DEVELOPER.md`, and `CLAUDE.md`. Leave the 2026-07-15 and 2026-07-17 spec bodies in place as history. This document is the process and packaging authority.

## 7. Testing

Add failing tests first for:

- Command parsing, including no-argument help, and rejection of `menubar` and `speak`
- The LaunchAgent template pointing at `daemon` and omitting `AssociatedBundleIdentifiers`
- Install placing the executable at `~/.local/bin/chorus` and not creating Chorus.app
- Idempotent reinstall
- Uninstall removing the executable only when the digest matches, and preserving it when the digest differs
- Removal of only a `com.chorus.tts` bundle at the two fixed application paths, including the refusal to delete a directory at `~/.local/bin/chorus`
- Doctor and skill or hook text that no longer mentions the menu bar or `chorus menubar`

Existing MCP, hook, speech, configuration, and daemon tests stay. Do not add a live audio test. Completion means `./scripts/with-xcode.sh swift test` and a release build both succeed.

## 8. Out of scope

- Restoring `chorus speak` or HTML comment speech envelopes
- A hidden menu bar flag or a second executable
- Python, Node, or any runtime wrapper
- Merging `ChorusCore` and `ChorusCLI`
- Rewriting the historical spec files
- A new live playback test
