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
└── ChorusCore/
    ├── EnvelopeParser.swift   strict invisible-envelope validation
    ├── HookAdapter.swift      Codex and Claude event adaptation
    ├── ModePolicy.swift       suppression and effective-volume policy
    ├── SpeechQueue.swift      bounded serialized speech queue
    ├── SupertonicBackend.swift
    ├── UnixSocket.swift       local daemon transport
    ├── ModelInstaller.swift   pinned download, checksum, and atomic swap
    ├── RuntimeInstaller.swift executable and LaunchAgent lifecycle
    ├── HostInstaller.swift    safe hook and skill merge/uninstall
    ├── LegacyMigration.swift  one-time allowlisted configuration import
    └── Diagnostics.swift      bounded current-state diagnostics
SwiftTests/
├── ChorusCoreTests/
└── ChorusIntegrationTests/
plugins/chorus/               marketplace metadata, five hooks, six skills
```

## Speech envelope

The only automatic speech request format is:

```text
<!-- chorus:speak {"v":1,"text":"...","voice":"F1","speed":0.93,"volume":0.85} -->
```

All fields are mandatory. Validation rejects unknown fields, invalid voice identifiers, non-finite values, and values outside the supported speed and volume ranges. Hook payloads without a valid envelope are ignored.

## Runtime lifecycle

`chorus install` performs staged executable installation, pinned model installation, hook and skill merge, LaunchAgent replacement, and a health-gated legacy service cutover. Owned-file digests prevent uninstall or repair from overwriting user modifications. Model activation uses a verified staging directory and atomic replacement.

The daemon writes its PID and serves the local Unix domain socket under the Chorus home. Speech requests are bounded, deduplicated, serialized, and played through the system audio framework.

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
