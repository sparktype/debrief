# Chorus developer guide

## Product boundary

Chorus is a macOS 14+ Apple Silicon TTS service delivered as one Swift executable. Its responsibilities are deliberately narrow:

1. install and verify the pinned Supertonic 3 model;
2. install the executable, LaunchAgent, five host hooks, and six TTS skills;
3. accept strict agent-provided speech envelopes;
4. synthesize with the local ONNX Runtime backend and play audio;
5. expose current-state `status` and `doctor` diagnostics.

The coding agent owns summarization and selects text, voice, speed, and volume.

## Source layout

```text
Package.swift
Sources/
├── ChorusCLI/                 command parsing and process entry point
│   ├── main.swift             subcommand dispatch (menubar / daemon / CLI)
│   ├── MenuBarApp.swift       LSUIElement NSStatusItem + NSMenu host
│   └── MenuBarModel.swift     menu actions against ResidentService
└── ChorusCore/
    ├── ResidentService.swift  pid + socket + in-process daemon lifecycle
    ├── ChorusDaemon.swift     speech accept loop over Unix socket
    ├── SpeechEnvelopeParser.swift  strict invisible-envelope validation
    ├── HookAdapters.swift     Codex and Claude event adaptation
    ├── ModePolicy.swift       suppression and effective-volume policy
    ├── SpeechQueue.swift      bounded serialized speech queue
    ├── SupertonicEngine.swift local ONNX TTS backend
    ├── UnixSocket.swift       local resident transport
    ├── MenuBarStatus.swift    pure status snapshot for menu header
    ├── ModelInstaller.swift   pinned download, checksum, and atomic swap
    ├── RuntimeInstaller.swift executable and LaunchAgent lifecycle
    ├── EmbeddedTemplates.swift hooks, skills, LaunchAgent (args: menubar)
    ├── HostInstaller.swift    safe hook and skill merge/uninstall
    ├── LegacyMigration.swift  one-time allowlisted configuration import
    └── Diagnostics.swift      bounded current-state diagnostics
SwiftTests/
├── ChorusCoreTests/
└── ChorusIntegrationTests/
plugins/chorus/               marketplace metadata, five hooks, six skills
```

## Process model

```text
Login / chorus install
        │
        ▼
LaunchAgent (com.chorus.tts)
        │ ProgramArguments: [<bin>/chorus, "menubar"]
        ▼
chorus (LSUIElement menu bar)
        ├── Menu: status · mute · mode · start · stop · quit
        └── ResidentService (in-process)
              ├── pid file
              ├── Unix socket server
              ├── ChorusDaemon + SpeechQueue
              ├── SupertonicEngine
              └── AudioPlayer

Codex / Claude ──► chorus hook ──► socket ──► ResidentService
CLI              ──► chorus speak|status|mute|mode|…
Debug            ──► chorus daemon (headless ResidentService; not install path)
```

## Speech envelope

The only automatic speech request format is:

```text
<!-- chorus:speak {"v":1,"text":"...","voice":"F1","speed":0.93,"volume":0.85} -->
```

All fields are mandatory. Validation rejects unknown fields, invalid voice identifiers, non-finite values, and values outside the supported speed and volume ranges. Hook payloads without a valid envelope are ignored.

## Runtime lifecycle

`chorus install` performs staged executable installation, pinned model installation, hook and skill merge, LaunchAgent replacement, and a health-gated legacy service cutover. Owned-file digests prevent uninstall or repair from overwriting user modifications. Model activation uses a verified staging directory and atomic replacement. LaunchAgent `ProgramArguments` are `[installedBinary, "menubar"]`.

The menu bar resident starts `ResidentService`, which writes its PID and serves the local Unix domain socket under the Chorus home. Speech requests are bounded, deduplicated, serialized, and played through the system audio framework. Menu Stop ends the in-process service only; the menu bar process stays up under LaunchAgent KeepAlive. Menu Quit boots out `com.chorus.tts` first, then stops the service and terminates so KeepAlive does not relaunch.

## Build and verification

```sh
swift test
swift build -c release
```

On the Command Line Tools 27 toolchain, the local environment may require the Testing plugin and runtime search-path flags documented in the implementation plan. Release verification must also inspect the executable architecture and linked libraries, then run installation and offline speech smoke tests from a clean temporary home.

## Change rules

- Add a focused failing test before behavior changes.
- Run impact analysis before editing an existing symbol.
- Keep the hook set and skill set exact; additions are product-scope changes.
- Do not persist hook payload text or synthesized audio.
- Preserve unrelated host settings and modified installed files.
- Run the full Swift suite and release build before claiming completion.
