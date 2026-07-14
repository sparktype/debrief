# Chorus Swift Single-Binary TTS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python Chorus runtime with one Apple Silicon Swift executable that installs Codex and Claude hooks/skills, accepts strict agent-authored speech envelopes, and performs local Supertonic TTS.

**Architecture:** A short-lived `chorus hook` adapter converts Codex and Claude lifecycle JSON into a shared event, validates the final HTML-comment envelope, and submits it over a user-only Unix domain socket. A LaunchAgent-managed `chorus daemon` keeps statically linked ONNX Runtime sessions and voice profiles resident, applies queue and mode policy, and plays audio through AVFoundation. The same executable owns model download, configuration merge, migration, diagnostics, and uninstall.

**Tech Stack:** Swift 6.0+, Swift Package Manager, macOS 14+, Swift Testing, Foundation, CryptoKit, AVFoundation, Darwin Unix sockets, ONNX Runtime Swift package 1.24.2, Supertonic 3 ONNX assets.

## Global Constraints

- Target Apple Silicon macOS 14 or later with Swift 6.0 or later; the release executable is arm64.
- Ship exactly one runtime executable named `chorus`; do not add runtime shell, Python, Node, app-bundle, or resource-bundle dependencies.
- Link ONNX Runtime statically and pin package version `1.24.2` exactly.
- Models, voices, settings, generated hooks/skills, and LaunchAgent plist remain external data.
- Chorus never calls an LLM, reads a transcript, summarizes, rewrites, or falls back to speaking the full assistant response.
- `text`, `voice`, `speed`, and `volume` are required agent-authored envelope fields.
- Keep only SessionStart, UserPromptSubmit, SubagentStart, Stop, and SubagentStop hooks.
- Preserve unrelated Codex and Claude settings and remove only checksum-matching Chorus-owned content.
- Do not add structured logging, metrics, history, digest, DLQ, usage tracking, circuit breakers, or persistent queue data.
- Before modifying any existing symbol, run GitNexus upstream impact analysis. Before every implementation commit, run GitNexus `detect_changes(scope: compare, base_ref: main)` when available; otherwise record the unavailable tool and run staged name/status plus targeted tests.
- Follow TDD: create a failing test, observe the intended failure, add the smallest implementation, rerun the focused test, then run the relevant suite.
- Preserve the user's existing uncommitted `.pyc` deletions and `.agents/`/`.codex/` additions unless a later cutover task explicitly owns them.

---

## File Structure

Create these focused production files:

```text
Package.swift
Sources/ChorusCore/
  ChorusVersion.swift          build/version constant
  ChorusPaths.swift            macOS data/cache/LaunchAgent paths
  SpeechEnvelope.swift         wire model and validation errors
  SpeechEnvelopeParser.swift   strict HTML-comment extraction
  VoiceCatalog.swift           agent category, voice, and speed assignments
  HookEvent.swift              normalized lifecycle event
  HookAdapters.swift           Codex/Claude input and output schemas
  HookEngine.swift             context injection and Stop delivery decisions
  ChorusConfiguration.swift    persisted mode/mute/volume ceilings
  ModePolicy.swift             event eligibility and gain clamping
  SpeechRequest.swift          socket request and priority model
  UnixSocket.swift             length-prefixed local transport
  SpeechQueue.swift            bounded actor queue and interruption decisions
  TTSBackend.swift             synthesis protocol
  SupertonicEngine.swift       ONNX sessions and synthesis orchestration
  SupertonicTensor.swift       ONNX tensor conversion helpers
  AudioPlayer.swift            AVAudioEngine playback
  ChorusDaemon.swift           socket, queue, synthesis, and playback loop
  ModelManifest.swift          pinned external asset description
  ModelInstaller.swift         URLSession download, digest, and activation
  InstallManifest.swift        exact ownership record
  EmbeddedTemplates.swift      in-binary hook/skill/plist templates
  HostInstaller.swift          safe Codex/Claude JSON merge and uninstall
  RuntimeInstaller.swift       executable copy, model install, and LaunchAgent bootstrap
  LegacyMigration.swift        legacy preference conversion and shutdown
  Diagnostics.swift            status, doctor, daemon state, last error
Sources/ChorusCLI/
  main.swift                   async executable entry
  Commands.swift               argument parsing and command dispatch
Tests/ChorusCoreTests/
Tests/ChorusIntegrationTests/
Tests/Fixtures/Hooks/
```

`EmbeddedTemplates.swift` uses Swift string literals. Do not use SwiftPM resources because that would create a runtime resource bundle beside the executable.

## Task 1: Bootstrap the Swift Package and CLI Contract

**Files:**
- Create: `Package.swift`
- Create: `Sources/ChorusCore/ChorusVersion.swift`
- Create: `Sources/ChorusCLI/main.swift`
- Create: `Sources/ChorusCLI/Commands.swift`
- Create: `Tests/ChorusCoreTests/ChorusVersionTests.swift`

**Interfaces:**
- Produces: `ChorusVersion.current: String`
- Produces: `ChorusCommand.parse(_:) throws -> ChorusCommand`
- Produces: cases for `install`, `uninstall`, `daemon`, `hook`, `speak`, `status`, `mute`, `mode`, and `doctor`

- [ ] **Step 1: Write the package smoke test before production source exists**

```swift
import Testing
@testable import ChorusCore

@Test func versionIsSemantic() {
    #expect(ChorusVersion.current == "2.0.0")
}
```

- [ ] **Step 2: Run the test and verify the package is missing**

Run: `swift test --filter versionIsSemantic`

Expected: FAIL because `Package.swift` or `ChorusCore` does not exist.

- [ ] **Step 3: Add the minimal package and version implementation**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chorus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "chorus", targets: ["ChorusCLI"])],
    targets: [
        .target(name: "ChorusCore"),
        .executableTarget(name: "ChorusCLI", dependencies: ["ChorusCore"]),
        .testTarget(name: "ChorusCoreTests", dependencies: ["ChorusCore"]),
        .testTarget(name: "ChorusIntegrationTests", dependencies: ["ChorusCore"]),
    ]
)
```

```swift
public enum ChorusVersion {
    public static let current = "2.0.0"
}
```

Define `ChorusCommand` as an `Equatable` enum with associated values matching the approved CLI. Reject unknown commands and missing required flags with `CommandError.usage(String)`. Keep parsing in Foundation only; do not add ArgumentParser.

- [ ] **Step 4: Run package tests and CLI help smoke test**

Run: `swift test && swift run chorus --help`

Expected: tests PASS; help lists all nine approved command groups and exits 0.

- [ ] **Step 5: Commit the package bootstrap**

```bash
git add Package.swift Sources/ChorusCore/ChorusVersion.swift Sources/ChorusCLI Tests/ChorusCoreTests/ChorusVersionTests.swift
git commit -m "feat: bootstrap Swift chorus executable"
```

## Task 2: Implement the Strict Speech Envelope

**Files:**
- Create: `Sources/ChorusCore/SpeechEnvelope.swift`
- Create: `Sources/ChorusCore/SpeechEnvelopeParser.swift`
- Create: `Tests/ChorusCoreTests/SpeechEnvelopeParserTests.swift`

**Interfaces:**
- Produces: `SpeechEnvelope(v:text:voice:speed:volume:)`
- Produces: `SpeechEnvelopeParser.extract(from:) -> SpeechEnvelope?`
- Produces: `SpeechEnvelope.validate(allowedVoices:) throws`

- [ ] **Step 1: Write failing parser and validation tests**

```swift
import Testing
@testable import ChorusCore

@Test func extractsLastValidEnvelope() throws {
    let message = """
    visible
    <!-- chorus:speak {"v":1,"text":"first","voice":"F1","speed":0.93,"volume":0.8} -->
    <!-- chorus:speak {"v":1,"text":"완료했습니다.","voice":"M4","speed":0.95,"volume":0.7} -->
    """
    let value = SpeechEnvelopeParser.extract(from: message)
    #expect(value?.text == "완료했습니다.")
    #expect(value?.voice == "M4")
}

@Test(arguments: [
    "<!-- chorus:speak {\"v\":1,\"text\":\"\",\"voice\":\"F1\",\"speed\":1,\"volume\":1} -->",
    "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"BAD\",\"speed\":1,\"volume\":1} -->",
    "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"F1\",\"speed\":2.1,\"volume\":1} -->",
    "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"F1\",\"speed\":1,\"volume\":1,\"extra\":true} -->",
])
func rejectsInvalidEnvelope(_ raw: String) {
    #expect(SpeechEnvelopeParser.extract(from: raw) == nil)
}
```

- [ ] **Step 2: Run focused tests and observe missing symbols**

Run: `swift test --filter SpeechEnvelopeParserTests`

Expected: FAIL because `SpeechEnvelope` and `SpeechEnvelopeParser` are undefined.

- [ ] **Step 3: Implement exact-key JSON decoding and validation**

```swift
public struct SpeechEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let text: String
    public let voice: String
    public let speed: Double
    public let volume: Double

    public func validate(allowedVoices: Set<String> = VoiceCatalog.allowedVoiceIDs) throws {
        guard v == 1 else { throw EnvelopeError.unsupportedVersion }
        guard !text.isEmpty, text.count <= 800, !text.contains("-->") else { throw EnvelopeError.invalidText }
        guard text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) || $0.value == 0x0A
        }) else { throw EnvelopeError.invalidText }
        guard allowedVoices.contains(voice) else { throw EnvelopeError.invalidVoice }
        guard speed.isFinite, (0.7...2.0).contains(speed) else { throw EnvelopeError.invalidSpeed }
        guard volume.isFinite, (0.0...1.0).contains(volume) else { throw EnvelopeError.invalidVolume }
    }
}
```

In `SpeechEnvelopeParser`, scan complete `<!-- chorus:speak ` / ` -->` spans from right to left. Before `JSONDecoder`, use `JSONSerialization` to assert that the key set equals `{"v","text","voice","speed","volume"}`. Return the first candidate from the right that decodes and validates; never throw to the hook caller.

- [ ] **Step 4: Run parser tests**

Run: `swift test --filter SpeechEnvelopeParserTests`

Expected: PASS, including malformed JSON, missing fields, extra keys, NaN, control characters, over-800 text, and multiple-envelope cases.

- [ ] **Step 5: Commit the envelope contract**

```bash
git add Sources/ChorusCore/SpeechEnvelope.swift Sources/ChorusCore/SpeechEnvelopeParser.swift Tests/ChorusCoreTests/SpeechEnvelopeParserTests.swift
git commit -m "feat: add strict speech envelope parser"
```

## Task 3: Port Agent Voice Assignments and Prompt Injection

**Files:**
- Create: `Sources/ChorusCore/VoiceCatalog.swift`
- Create: `Tests/ChorusCoreTests/VoiceCatalogTests.swift`
- Read source of truth: `plugins/chorus/runtime/voice-map.json`

**Interfaces:**
- Produces: `VoiceAssignment(category:voice:name:baselineSpeed:)`
- Produces: `VoiceCatalog.assignment(for agentType: String?) -> VoiceAssignment`
- Produces: `VoiceCatalog.context(for agentType: String?) -> String`

- [ ] **Step 1: Write representative and completeness tests**

```swift
@Test(arguments: [
    ("code-reviewer", "M3"),
    ("planner", "M1"),
    ("feature-builder", "M4"),
    ("e2e-runner", "F2"),
    ("explore", "F3"),
    ("code-simplifier", "M3"),
    ("security-reviewer", "M3"),
    ("dependency-expert", "F5"),
    ("unknown-agent", "F1"),
])
func preservesVoiceRouting(agentType: String, voice: String) {
    #expect(VoiceCatalog.assignment(for: agentType).voice == voice)
}

@Test func contextRequiresAllEnvelopeFields() {
    let text = VoiceCatalog.context(for: "planner")
    #expect(text.contains("\"voice\":\"M1\""))
    #expect(text.contains("\"speed\":1.1"))
    #expect(text.contains("\"volume\""))
    #expect(text.contains("exactly one"))
}
```

- [ ] **Step 2: Run tests and observe missing catalog**

Run: `swift test --filter VoiceCatalogTests`

Expected: FAIL because `VoiceCatalog` is undefined.

- [ ] **Step 3: Implement in-binary routing constants**

Define the approved category assignments exactly:

```swift
private static let assignments: [String: VoiceAssignment] = [
    "reviewer": .init(category: "reviewer", voice: "M3", name: "일론", baselineSpeed: 1.00),
    "planner": .init(category: "planner", voice: "M1", name: "스티브", baselineSpeed: 1.10),
    "builder": .init(category: "builder", voice: "M4", name: "리누스", baselineSpeed: 0.95),
    "tester": .init(category: "tester", voice: "F2", name: "마리", baselineSpeed: 1.10),
    "explorer": .init(category: "explorer", voice: "F3", name: "제인", baselineSpeed: 1.00),
    "optimizer": .init(category: "optimizer", voice: "M3", name: "일론", baselineSpeed: 1.00),
    "guardian": .init(category: "guardian", voice: "M5", name: "팀", baselineSpeed: 0.88),
    "ops": .init(category: "ops", voice: "F4", name: "셰릴", baselineSpeed: 1.05),
    "specialist": .init(category: "specialist", voice: "F5", name: "리사", baselineSpeed: 0.88),
    "default": .init(category: "default", voice: "F1", name: "연아", baselineSpeed: 0.93),
]
```

Port every agent-type string from the existing `categories` object into a Swift `[String: String]` lookup and add `explore`, `researcher`, `dependency-expert`, `executor`, `debugger`, `test-engineer`, `verifier`, and `critic` aliases according to their semantic category. `context(for:)` must explicitly require a one- or two-sentence summary and the five-field single-line envelope; it must not instruct Chorus to summarize.

- [ ] **Step 4: Run voice tests and compare all legacy category entries**

Run: `swift test --filter VoiceCatalogTests`

Expected: PASS and a completeness test confirms every legacy `categories` entry appears once in the Swift lookup.

- [ ] **Step 5: Commit voice routing**

```bash
git add Sources/ChorusCore/VoiceCatalog.swift Tests/ChorusCoreTests/VoiceCatalogTests.swift
git commit -m "feat: port agent voice assignments"
```

## Task 4: Normalize Codex and Claude Hook Events

**Files:**
- Create: `Sources/ChorusCore/HookEvent.swift`
- Create: `Sources/ChorusCore/HookAdapters.swift`
- Create: `Sources/ChorusCore/HookEngine.swift`
- Create: `Sources/ChorusCore/SpeechRequest.swift`
- Create: `Tests/Fixtures/Hooks/codex-*.json`
- Create: `Tests/Fixtures/Hooks/claude-*.json`
- Create: `Tests/ChorusCoreTests/HookTestSupport.swift`
- Create: `Tests/ChorusCoreTests/HookAdapterTests.swift`
- Create: `Tests/ChorusCoreTests/HookEngineTests.swift`

**Interfaces:**
- Produces: `HostSource.codex|claude`
- Produces: `HookEventName.sessionStart|userPromptSubmit|subagentStart|stop|subagentStop`
- Produces: `HookEvent(name:sessionID:turnID:agentType:lastAssistantMessage:)`
- Produces: `HookAdapter.decode(_:source:) throws -> HookEvent`
- Produces: `HookAdapter.contextOutput(_:source:event:) throws -> Data`
- Produces: `HookAdapter.successOutput(source:event:) throws -> Data`
- Produces: `SpeechRequest(envelope:event:agentType:)`
- Consumes: `SpeechEnvelopeParser` and `VoiceCatalog`

- [ ] **Step 1: Add fixtures for all five events from official schemas**

Store minimal fixture JSON for SessionStart, UserPromptSubmit, SubagentStart, Stop, and SubagentStop for each host. Stop fixtures must include a valid envelope in `last_assistant_message`; SubagentStart/Stop fixtures must include `agent_type`.

`HookTestSupport.swift` provides `Fixture.load(_:)` and an actor-backed `RecordingSink` implementing `SpeechSink`; these helpers stay in the test target.

- [ ] **Step 2: Write failing adapter and engine tests**

```swift
@Test func codexStopNormalizesEnvelopeText() throws {
    let data = try Fixture.load("codex-stop.json")
    let event = try HookAdapter.decode(data, source: .codex)
    #expect(event.name == .stop)
    #expect(event.lastAssistantMessage?.contains("chorus:speak") == true)
}

@Test func subagentContextUsesAssignedVoice() async throws {
    let event = HookEvent(name: .subagentStart, sessionID: "s", turnID: "t", agentType: "planner", lastAssistantMessage: nil)
    let result = await HookEngine(sink: RecordingSink()).handle(event, source: .claude)
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("M1"))
}
```

- [ ] **Step 3: Run focused tests and observe missing adapters**

Run: `swift test --filter HookAdapterTests && swift test --filter HookEngineTests`

Expected: FAIL because hook types are undefined.

- [ ] **Step 4: Implement strict host adapters and engine behavior**

Use a shared sink boundary:

```swift
public protocol SpeechSink: Sendable {
    func submit(_ request: SpeechRequest) async throws
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let envelope: SpeechEnvelope
    public let event: HookEventName
    public let agentType: String?
}

public struct HookResult: Sendable {
    public let stdout: Data
    public let submitted: Bool
}
```

Context events return host-specific `hookSpecificOutput.additionalContext`. Stop events parse only `last_assistant_message`, verify that envelope voice equals `VoiceCatalog.assignment(for: event.agentType).voice`, and submit once. Missing/invalid/mismatched envelopes return the host's successful no-op JSON. Never return a Stop continuation decision.

- [ ] **Step 5: Run all hook tests**

Run: `swift test --filter HookAdapterTests && swift test --filter HookEngineTests`

Expected: PASS for ten fixtures, invalid envelopes, wrong assigned voice, empty assistant messages, and sink failure.

- [ ] **Step 6: Perform the host preservation gate**

Install a temporary no-speech capture hook in a disposable Codex and Claude session, emit the approved HTML comment, and save the captured Stop payload as `codex-stop-live.json` and `claude-stop-live.json`. Confirm the raw `last_assistant_message` retains the complete comment. Stop implementation if either host strips it; do not add transcript parsing.

- [ ] **Step 7: Commit hook normalization**

```bash
git add Sources/ChorusCore/HookEvent.swift Sources/ChorusCore/HookAdapters.swift Sources/ChorusCore/HookEngine.swift Sources/ChorusCore/SpeechRequest.swift Tests/Fixtures/Hooks Tests/ChorusCoreTests/HookAdapterTests.swift Tests/ChorusCoreTests/HookEngineTests.swift
git commit -m "feat: add Codex and Claude hook adapters"
```

## Task 5: Add Paths, Configuration, and Mode Policy

**Files:**
- Create: `Sources/ChorusCore/ChorusPaths.swift`
- Create: `Sources/ChorusCore/ChorusConfiguration.swift`
- Create: `Sources/ChorusCore/ModePolicy.swift`
- Create: `Tests/ChorusCoreTests/ConfigurationTests.swift`
- Create: `Tests/ChorusCoreTests/ModePolicyTests.swift`

**Interfaces:**
- Produces: `ChorusPaths.forHome(_:)`
- Produces: `ChorusConfiguration.load(from:)`, `.save(to:)`
- Produces: `ModePolicy.admit(event:requestedVolume:configuration:) -> Double?`

- [ ] **Step 1: Write failing path, atomic-save, and mode tests**

```swift
@Test func nightCapsMainAndRejectsSubagent() {
    let config = ChorusConfiguration(mode: .night, muted: false)
    #expect(ModePolicy.admit(event: .stop, requestedVolume: 0.9, configuration: config) == 0.20)
    #expect(ModePolicy.admit(event: .subagentStop, requestedVolume: 0.1, configuration: config) == nil)
}

@Test func muteRejectsEverything() {
    let config = ChorusConfiguration(mode: .verbose, muted: true)
    #expect(ModePolicy.admit(event: .stop, requestedVolume: 0.8, configuration: config) == nil)
}
```

- [ ] **Step 2: Run tests and observe missing types**

Run: `swift test --filter ConfigurationTests && swift test --filter ModePolicyTests`

Expected: FAIL with undefined configuration and policy symbols.

- [ ] **Step 3: Implement standard paths and policy**

Default ceilings are `normal=1.0`, `focus=1.0`, `quiet=0.45`, `verbose=1.0`, and `night=0.20`. `focus`, `quiet`, and `night` reject subagent events. Save JSON by writing a sibling temporary file, `fsync`, then rename. Create directories with user-only permissions.

- [ ] **Step 4: Run configuration and mode tests**

Run: `swift test --filter ConfigurationTests && swift test --filter ModePolicyTests`

Expected: PASS for defaults, corrupt-file recovery to defaults, atomic replacement, mute, event filtering, and gain clamping.

- [ ] **Step 5: Wire and test `chorus mode` and `chorus mute`**

Update `Commands.swift` so mode writes one of the five enum values atomically and mute supports `on`, `off`, and `toggle`. Add `Tests/ChorusIntegrationTests/ConfigurationCommandTests.swift` using a temporary home and assert the resulting `config.json` rather than process-global user paths.

Run: `swift test --filter ConfigurationCommandTests`

Expected: PASS for all mode values, mute transitions, invalid arguments, and atomic persistence.

- [ ] **Step 6: Commit configuration policy**

```bash
git add Sources/ChorusCore/ChorusPaths.swift Sources/ChorusCore/ChorusConfiguration.swift Sources/ChorusCore/ModePolicy.swift Tests/ChorusCoreTests/ConfigurationTests.swift Tests/ChorusCoreTests/ModePolicyTests.swift
git commit -m "feat: add local TTS mode policy"
```

## Task 6: Implement the Unix Socket Protocol

**Files:**
- Create: `Sources/ChorusCore/UnixSocket.swift`
- Create: `Tests/ChorusIntegrationTests/UnixSocketTests.swift`
- Create: `Tests/ChorusIntegrationTests/HookCommandIntegrationTests.swift`

**Interfaces:**
- Produces: `UnixSocketServer.accept() async throws -> SpeechRequest`
- Produces: `UnixSocketClient.submit(_:) async throws`

- [ ] **Step 1: Write failing round-trip and permission tests**

```swift
@Test func socketRoundTripUsesUserOnlyPermissions() async throws {
    let harness = try SocketHarness()
    let envelope = SpeechEnvelope(v: 1, text: "완료", voice: "F1", speed: 0.93, volume: 0.6)
    let fixture = SpeechRequest(envelope: envelope, event: .stop, agentType: nil)
    async let received = harness.server.accept()
    try await harness.client.submit(fixture)
    #expect(try await received == fixture)
    #expect(harness.socketMode == 0o600)
}
```

- [ ] **Step 2: Run test and observe missing transport**

Run: `swift test --filter UnixSocketTests`

Expected: FAIL because socket types are undefined.

- [ ] **Step 3: Implement a bounded length-prefixed protocol with Darwin sockets**

Frame format is four-byte big-endian payload length followed by UTF-8 JSON. Reject payloads over 16 KiB. Server responds with one byte: `0x06` for accepted or `0x15` for rejected. Set the containing cache directory to `0700` and socket file to `0600`; unlink only an existing socket owned by the current user. Client connect and acknowledgement timeouts are 150 ms each, with one retry.

- [ ] **Step 4: Run transport tests**

Run: `swift test --filter UnixSocketTests`

Expected: PASS for round trip, partial reads, oversized frames, stale owned socket, wrong-owner refusal, timeout, and permissions.

- [ ] **Step 5: Wire `chorus hook` to `UnixSocketClient` and test stdin/stdout**

Run: `swift test --filter HookCommandIntegrationTests`

Expected: a valid fixture produces one socket request and host success JSON; an unavailable socket still exits 0 after the bounded retry.

- [ ] **Step 6: Commit local transport**

```bash
git add Sources/ChorusCore/UnixSocket.swift Sources/ChorusCLI Tests/ChorusIntegrationTests
git commit -m "feat: submit hook speech over unix socket"
```

## Task 7: Build the Bounded Priority Queue

**Files:**
- Create: `Sources/ChorusCore/SpeechQueue.swift`
- Create: `Tests/ChorusCoreTests/SpeechQueueTests.swift`

**Interfaces:**
- Produces: `actor SpeechQueue`
- Produces: `enqueue(_:) -> QueueDecision`
- Produces: `next() async -> SpeechRequest`
- Produces: `shouldInterruptActive(active:incoming:) -> Bool`

- [ ] **Step 1: Write failing priority, capacity, and deduplication tests**

```swift
@Test func mainEvictsQueuedSubagents() async {
    let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))
    await queue.enqueue(request(.subagentStop, "one"))
    await queue.enqueue(request(.subagentStop, "two"))
    await queue.enqueue(request(.stop, "done"))
    #expect(await queue.pendingTexts == ["done"])
}

@Test func mainInterruptsOnlyActiveSubagent() async {
    let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))
    #expect(await queue.shouldInterruptActive(active: request(.subagentStop, "x"), incoming: request(.stop, "y")))
    #expect(!(await queue.shouldInterruptActive(active: request(.stop, "x"), incoming: request(.stop, "y"))))
}
```

Define the test-local `request(_:_:)` helper to construct a valid F1 envelope with speed `0.93` and volume `0.6`; production code does not gain test convenience factories.

- [ ] **Step 2: Run focused tests and observe missing actor**

Run: `swift test --filter SpeechQueueTests`

Expected: FAIL because `SpeechQueue` is undefined.

- [ ] **Step 3: Implement in-memory queue rules**

Use a monotonic clock and an in-memory digest of the canonical encoded envelope for three-second duplicate suppression. Never persist requests or digests. When full, reject the oldest lowest-priority queued subagent first; if all queued items are main, reject the incoming request.

- [ ] **Step 4: Run queue tests**

Run: `swift test --filter SpeechQueueTests`

Expected: PASS for ordering, eviction, active interruption, capacity eight, duplicate window, and continuation after rejection.

- [ ] **Step 5: Commit queue behavior**

```bash
git add Sources/ChorusCore/SpeechQueue.swift Tests/ChorusCoreTests/SpeechQueueTests.swift
git commit -m "feat: add bounded TTS priority queue"
```

## Task 8: Port Supertonic 3 to the Static Swift Backend

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ChorusCore/TTSBackend.swift`
- Create: `Sources/ChorusCore/SupertonicEngine.swift`
- Create: `Sources/ChorusCore/SupertonicTensor.swift`
- Create: `Tests/ChorusCoreTests/SupertonicTensorTests.swift`
- Create: `Tests/ChorusIntegrationTests/SupertonicSmokeTests.swift`
- Reference: `https://github.com/supertone-inc/supertonic/blob/main/swift/Sources/ExampleONNX.swift`
- Reference: `https://github.com/supertone-inc/supertonic/blob/main/swift/Sources/Helper.swift`

**Interfaces:**
- Produces: `protocol TTSBackend { func synthesize(text:voice:speed:) async throws -> PCMBuffer }`
- Produces: `PCMBuffer(sampleRate:channels:samples:)` with mono Float32 samples
- Produces: `SupertonicEngine.init(modelDirectory:)`
- Produces: `SupertonicEngine.synthesize(text:voice:speed:) async throws -> PCMBuffer`

- [ ] **Step 1: Add deterministic tensor-helper tests before ONNX integration**

Test padding, mask construction, chunk concatenation, 44.1 kHz float conversion, and sentence splitting against fixed small arrays. The tests must not require model assets.

- [ ] **Step 2: Run tests and observe missing Supertonic helpers**

Run: `swift test --filter SupertonicTensorTests`

Expected: FAIL because helper symbols are undefined.

- [ ] **Step 3: Pin static ONNX Runtime and port the official Swift algorithm**

Add exactly:

```swift
dependencies: [
    .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
]
```

and link `.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")` to `ChorusCore`.

Port the inference and helper logic from the two official Supertonic Swift source files into the focused files above. Remove their CLI, file-output, batch-demo, and benchmark code. Keep sessions resident, pass `lang="ko"`, use the envelope speed, use eight denoising steps, load voice JSON only from the installed voice directory, and return interleaved mono Float32 samples at 44.1 kHz.

Define the shared buffer explicitly:

```swift
public struct PCMBuffer: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let samples: [Float]
}
```

- [ ] **Step 4: Run helper tests and a model-gated smoke test**

Run: `swift test --filter SupertonicTensorTests`

Expected: PASS without model assets.

Run: `CHORUS_TEST_MODEL_DIR="$HOME/Library/Application Support/Chorus/models/supertonic-3/current" swift test --filter SupertonicSmokeTests`

Expected: PASS when assets exist; SKIP with an explicit reason when the environment variable is absent.

- [ ] **Step 5: Verify static dependency shape**

Run: `swift build -c release && otool -L .build/release/chorus`

Expected: no `onnxruntime.framework`, Homebrew path, Python library, or non-system dylib.

- [ ] **Step 6: Commit the synthesis backend**

```bash
git add Package.swift Package.resolved Sources/ChorusCore/TTSBackend.swift Sources/ChorusCore/SupertonicEngine.swift Sources/ChorusCore/SupertonicTensor.swift Tests/ChorusCoreTests/SupertonicTensorTests.swift Tests/ChorusIntegrationTests/SupertonicSmokeTests.swift
git commit -m "feat: add static Supertonic Swift backend"
```

## Task 9: Add AVFoundation Playback and the Daemon Loop

**Files:**
- Create: `Sources/ChorusCore/AudioPlayer.swift`
- Create: `Sources/ChorusCore/ChorusDaemon.swift`
- Create: `Tests/ChorusCoreTests/AudioPlayerTests.swift`
- Create: `Tests/ChorusIntegrationTests/DaemonTests.swift`

**Interfaces:**
- Produces: `AudioPlaying.play(_:gain:) async throws`
- Produces: `AudioPlaying.stop() async`
- Produces: `ChorusDaemon.run() async throws`
- Consumes: `UnixSocketServer`, `SpeechQueue`, `ModePolicy`, and `TTSBackend`

- [ ] **Step 1: Write failing daemon tests with fake synthesis and audio**

Test accepted request order, main-over-subagent interruption, gain clamping, synthesis failure continuation, audio rebuild once, and clean SIGTERM shutdown. Fake backends record calls and never access an audio device.

- [ ] **Step 2: Run tests and observe missing daemon**

Run: `swift test --filter DaemonTests`

Expected: FAIL because daemon and audio interfaces are undefined.

- [ ] **Step 3: Implement AVAudioEngine playback and daemon orchestration**

Create an `AVAudioPCMBuffer` with mono Float32 44.1 kHz format, multiply samples by the admitted gain, schedule it on `AVAudioPlayerNode`, and bridge completion to async continuation. The daemon accepts socket requests, applies current configuration, enqueues admitted work, synthesizes serially, and interrupts only active subagent audio when a main request arrives.

- [ ] **Step 4: Run daemon tests and direct fake-backend CLI smoke test**

Run: `swift test --filter AudioPlayerTests && swift test --filter DaemonTests`

Expected: PASS without using the physical output device.

- [ ] **Step 5: Wire `chorus daemon` and `chorus speak`**

`daemon` constructs real paths, configuration, socket server, `SupertonicEngine`, and `AudioPlayer`, then awaits `ChorusDaemon.run()`. `speak` requires text, voice, speed, and volume, validates them through `SpeechEnvelope`, wraps a main `SpeechRequest`, and submits through `UnixSocketClient`. Unlike hooks, a direct CLI socket failure exits nonzero with stderr.

Add `Tests/ChorusIntegrationTests/SpeakCommandIntegrationTests.swift` and run: `swift test --filter SpeakCommandIntegrationTests`

Expected: valid fields submit once; missing or invalid fields return usage failure; an unavailable daemon returns nonzero.

- [ ] **Step 6: Commit daemon and playback**

```bash
git add Sources/ChorusCore/AudioPlayer.swift Sources/ChorusCore/ChorusDaemon.swift Sources/ChorusCLI Tests/ChorusCoreTests/AudioPlayerTests.swift Tests/ChorusIntegrationTests/DaemonTests.swift
git commit -m "feat: add resident TTS daemon and playback"
```

## Task 10: Implement Pinned Model Download and Repair

**Files:**
- Create: `Sources/ChorusCore/ModelManifest.swift`
- Create: `Sources/ChorusCore/ModelInstaller.swift`
- Create: `Tests/ChorusCoreTests/ModelManifestTests.swift`
- Create: `Tests/ChorusIntegrationTests/ModelInstallerTests.swift`

**Interfaces:**
- Produces: `ModelManifest.supertonic3`
- Produces: `ModelInstaller.install(repair:) async throws -> InstalledModel`

- [ ] **Step 1: Resolve and record immutable upstream metadata**

Resolve the full commit SHA behind the approved Supertonic 3 Hugging Face revision whose current short SHA begins `3cadd1e`. Enumerate `onnx/`, `voice_styles/F1...F5.json`, `voice_styles/M1...M5.json`, and required config files. Compute byte sizes and SHA-256 digests. Store the immutable `resolve/<full-sha>/...` URLs and values as Swift literals in `ModelManifest.swift`; never store `main` URLs.

- [ ] **Step 2: Write failing manifest and interrupted-download tests**

Tests assert unique relative paths, HTTPS immutable URLs, 64-character lowercase digests, required ten voices, rejection of traversal paths, checksum failure preserving the old revision, and repair fetching only missing files.

- [ ] **Step 3: Run tests and observe missing installer**

Run: `swift test --filter ModelManifestTests && swift test --filter ModelInstallerTests`

Expected: FAIL because manifest and installer are undefined.

- [ ] **Step 4: Implement URLSession staging, SHA-256, and atomic activation**

Download to `<models>/.staging-<UUID>`, validate size and CryptoKit SHA-256 for every file, write a validated revision marker, `fsync`, then rename to `<models>/supertonic-3/<sha>`. Update a small `current.json` pointer atomically only after the directory is complete. On error, remove only the staging directory and leave the previous current revision untouched.

- [ ] **Step 5: Run model tests**

Run: `swift test --filter ModelManifestTests && swift test --filter ModelInstallerTests`

Expected: PASS using a local URLProtocol/test server; no public-network dependency in automated tests.

- [ ] **Step 6: Commit model management**

```bash
git add Sources/ChorusCore/ModelManifest.swift Sources/ChorusCore/ModelInstaller.swift Tests/ChorusCoreTests/ModelManifestTests.swift Tests/ChorusIntegrationTests/ModelInstallerTests.swift
git commit -m "feat: install pinned Supertonic models"
```

## Task 11: Install Hooks, Skills, and LaunchAgent Safely

**Files:**
- Create: `Sources/ChorusCore/InstallManifest.swift`
- Create: `Sources/ChorusCore/EmbeddedTemplates.swift`
- Create: `Sources/ChorusCore/HostInstaller.swift`
- Create: `Sources/ChorusCore/RuntimeInstaller.swift`
- Create: `Tests/ChorusCoreTests/EmbeddedTemplatesTests.swift`
- Create: `Tests/ChorusIntegrationTests/HostInstallerTests.swift`
- Create: `Tests/ChorusIntegrationTests/RuntimeInstallerTests.swift`
- Modify: `Sources/ChorusCLI/Commands.swift`

**Interfaces:**
- Produces: `HostInstaller.install(hosts:) throws`
- Produces: `HostInstaller.uninstall(hosts:) throws`
- Produces: `RuntimeInstaller.install(hosts:repair:) async throws`
- Produces: `RuntimeInstaller.uninstall(hosts:) async throws`
- Produces: exact Chorus-owned entry digests in `InstallManifest`

- [ ] **Step 1: Write failing safe-merge and template tests**

Cover both absent and populated settings, five exact hook events, six skills, duplicate-free reinstall, atomic backup, uninstall of unchanged owned entries, preservation of user-edited files, and preservation of unrelated hooks/MCP entries. Runtime tests use a fake model installer and launchctl runner to verify atomic executable copy to `~/.local/bin/chorus`, mode `0755`, model-before-daemon ordering, idempotent LaunchAgent bootstrap, and self-unlink only after daemon unload during uninstall.

- [ ] **Step 2: Run tests and observe missing installer**

Run: `swift test --filter EmbeddedTemplatesTests && swift test --filter HostInstallerTests && swift test --filter RuntimeInstallerTests`

Expected: FAIL because embedded templates and installer are undefined.

- [ ] **Step 3: Implement in-binary templates**

Hook commands must be the absolute installed executable plus `hook --source codex` or `hook --source claude`. Generate only SessionStart, UserPromptSubmit, SubagentStart, Stop, and SubagentStop. Embed setup, status, mode, mute, speak, and doctor `SKILL.md` content as Swift multiline strings; do not emit listen or digest.

The LaunchAgent uses `ProgramArguments = [absoluteBinary, "daemon"]`, `RunAtLoad = true`, and `KeepAlive = true`. It must not invoke a shell.

`RuntimeInstaller` copies the currently executing release binary through a temporary sibling into `~/.local/bin/chorus`, applies mode `0755`, installs or repairs the pinned model, writes the LaunchAgent, and invokes `/bin/launchctl bootstrap gui/<uid> <plist>` directly with `Process`. Host templates always point to the installed path, never the transient source path.

- [ ] **Step 4: Implement ownership-aware JSON merge and uninstall**

Read the existing host JSON as an object, append exact Chorus hook objects only when absent, back up before first mutation, write atomically, and record SHA-256 for every generated skill and exact serialized hook object. Uninstall removes only matching owned values. For Codex, print the required `/hooks` trust review notice after install.

- [ ] **Step 5: Run installer tests**

Run: `swift test --filter EmbeddedTemplatesTests && swift test --filter HostInstallerTests && swift test --filter RuntimeInstallerTests`

Expected: PASS for Codex and Claude fixtures, malformed-settings refusal, reinstall, uninstall, and user edits.

- [ ] **Step 6: Commit integration installation**

```bash
git add Sources/ChorusCore/InstallManifest.swift Sources/ChorusCore/EmbeddedTemplates.swift Sources/ChorusCore/HostInstaller.swift Sources/ChorusCore/RuntimeInstaller.swift Sources/ChorusCLI/Commands.swift Tests/ChorusCoreTests/EmbeddedTemplatesTests.swift Tests/ChorusIntegrationTests/HostInstallerTests.swift Tests/ChorusIntegrationTests/RuntimeInstallerTests.swift
git commit -m "feat: install Chorus hooks and skills"
```

## Task 12: Add Migration, Status, Doctor, and Last-Error State

**Files:**
- Create: `Sources/ChorusCore/LegacyMigration.swift`
- Create: `Sources/ChorusCore/Diagnostics.swift`
- Create: `Tests/ChorusCoreTests/LegacyMigrationTests.swift`
- Create: `Tests/ChorusIntegrationTests/DiagnosticsTests.swift`
- Modify: `Sources/ChorusCLI/Commands.swift`

**Interfaces:**
- Produces: `LegacyMigration.plan(from:) -> MigrationPlan`
- Produces: `LegacyMigration.apply(_:afterHealthCheck:)`
- Produces: `Diagnostics.status() -> StatusSnapshot`
- Produces: `Diagnostics.doctor() -> [DiagnosticFinding]`

- [ ] **Step 1: Write failing migration allowlist tests**

Tests provide a full legacy config and assert that only mute/autoSpeak, mode, category voice, per-voice speed, and volume ceiling migrate. Assert that LLM keys, transcript paths, metrics, history, STT, and HTTP settings never appear in the new config.

- [ ] **Step 2: Write failing diagnostics tests**

Cover healthy daemon/model/socket, stale PID, missing model, invalid digest marker, unreadable host config, and a single atomically replaced `last-error.json`. Assert that status has no history, counters, request text, or metrics.

- [ ] **Step 3: Run tests and observe missing migration/diagnostics**

Run: `swift test --filter LegacyMigrationTests && swift test --filter DiagnosticsTests`

Expected: FAIL because migration and diagnostics types are undefined.

- [ ] **Step 4: Implement guarded migration and legacy shutdown**

Build a `MigrationPlan` without side effects, install and start the Swift daemon, run model/socket health checks, then unload only known legacy Chorus Python LaunchAgent labels. If health fails, leave legacy services loaded and return nonzero from `install`. Remove a legacy Chorus-owned MCP or `node_repl` entry only on exact object match.

- [ ] **Step 5: Implement minimal current-state diagnostics**

`last-error.json` contains only `timestamp`, `component`, `code`, and a bounded non-user-content `message`. Every write replaces the previous file. `status` and `doctor` read current configuration, socket, process, model revision, hook ownership, and skill ownership only.

- [ ] **Step 6: Run migration and diagnostics tests**

Run: `swift test --filter LegacyMigrationTests && swift test --filter DiagnosticsTests`

Expected: PASS, including failed-health rollback and absence of removed fields.

- [ ] **Step 7: Commit migration and diagnostics**

```bash
git add Sources/ChorusCore/LegacyMigration.swift Sources/ChorusCore/Diagnostics.swift Sources/ChorusCLI/Commands.swift Tests/ChorusCoreTests/LegacyMigrationTests.swift Tests/ChorusIntegrationTests/DiagnosticsTests.swift
git commit -m "feat: migrate and diagnose Swift Chorus"
```

## Task 13: Cut Over the Plugin and Delete the Legacy Runtime

**Files:**
- Modify: `plugins/chorus/.codex-plugin/plugin.json`
- Modify: `plugins/chorus/hooks/hooks.json`
- Modify: `plugins/chorus/hooks/claude-hooks.json`
- Modify: `plugins/chorus/skills/*/SKILL.md`
- Modify: `README.md`
- Modify: `ONBOARDING.md`
- Modify: `DEVELOPER.md`
- Delete: `hook_voice/`
- Delete: `tts_server/`
- Delete: `plugins/chorus/runtime/`
- Delete: `hooks/*.sh`
- Delete: `scripts/build-plugin-runtime.sh`
- Delete: `plugins/chorus/scripts/chorus-hook`
- Delete: `plugins/chorus/scripts/chorus-runtime`
- Delete: removed Python tests under `tests/`
- Delete: `runtime-requirements.txt`, `pytest.ini`, `server.sh`, `install.sh`, `uninstall.sh`, and `setup-tts.sh`

**Interfaces:**
- Consumes: the complete Swift executable and embedded installer
- Produces: a plugin and documentation surface advertising only TTS-only Swift behavior

- [ ] **Step 1: Add repository contract tests before deletion**

Create `Tests/ChorusIntegrationTests/RepositoryCutoverTests.swift` that scans the repository root and asserts:

```swift
#expect(!FileManager.default.fileExists(atPath: root + "/hook_voice"))
#expect(!FileManager.default.fileExists(atPath: root + "/tts_server"))
#expect(pluginHookEvents == Set(["SessionStart", "UserPromptSubmit", "SubagentStart", "Stop", "SubagentStop"]))
#expect(allHookCommands.allSatisfy { $0.contains("chorus hook --source") })
#expect(!activePluginAndCurrentDocsText.contains("node_repl"))
```

Limit this text assertion to active plugin manifests/scripts and current user documentation. Historical `docs/superpowers/` files and the exact-match legacy migration implementation are exempt.

- [ ] **Step 2: Run the cutover test and verify it fails on legacy files**

Run: `swift test --filter RepositoryCutoverTests`

Expected: FAIL listing the legacy runtime and obsolete hook events.

- [ ] **Step 3: Run impact analysis before changing existing manifests or deleting symbols**

Use GitNexus context/impact on `plugins/chorus/hooks/hooks.json`, `hook_dispatch`, `handle_hook`, `handle_subagent_stop`, `runtime_manager`, and `tts_server.server`. If any result is HIGH or CRITICAL, report the blast radius before deletion and confirm the approved design covers each caller.

- [ ] **Step 4: Switch active manifests and docs to the Swift installer**

Keep only the five hooks and six skills. Replace Python setup commands with `chorus install`, repair with `chorus install --repair`, and runtime checks with `chorus status`/`chorus doctor`. Remove claims for STT, LLM summary, transcript fallback, observability, digest, HTTP, and MCP.

- [ ] **Step 5: Delete the legacy implementation and obsolete tests**

Delete only the paths owned by this task. Preserve historical design documents and unrelated user-created `.agents/` and `.codex/` content. Remove tracked `.pyc` files and add Python cache patterns to `.gitignore` if not already present.

- [ ] **Step 6: Run the cutover and full Swift suites**

Run: `swift test`

Expected: PASS; no Python test runner is required.

Run: `rg -n "python|uv run|FastAPI|Whisper|node_repl|Prometheus|digest|listen" plugins README.md ONBOARDING.md DEVELOPER.md Sources Tests`

Expected: no active runtime reference except intentional migration diagnostics and negative test assertions.

- [ ] **Step 7: Commit the cutover**

```bash
git add Package.swift Package.resolved Sources Tests plugins README.md ONBOARDING.md DEVELOPER.md .gitignore
git add -u hook_voice tts_server hooks scripts runtime-requirements.txt pytest.ini server.sh install.sh uninstall.sh setup-tts.sh
git diff --cached --name-status
git commit -m "refactor: replace legacy Chorus runtime with Swift"
```

Before committing, confirm the staged list contains no unrelated `.agents/`, `.codex/`, or user-owned path.

## Task 14: Release Verification and Offline Acceptance

**Files:**
- Create: `docs/release/swift-single-binary-checklist.md`
- Modify: `README.md`

**Interfaces:**
- Produces: reproducible evidence that the approved design is complete

- [ ] **Step 1: Run clean tests and release build**

Run:

```bash
swift package reset
swift test
swift build -c release
file .build/release/chorus
otool -L .build/release/chorus
```

Expected: all tests PASS; `file` reports arm64; `otool -L` lists only system libraries and frameworks.

- [ ] **Step 2: Verify one-runtime-file packaging**

Copy only `.build/release/chorus` to an empty temporary directory and run `./chorus --help` and `./chorus status`.

Expected: both commands run without an adjacent bundle, framework, Python, Node, or shell script.

- [ ] **Step 3: Run model-backed voice smoke tests**

Run `chorus install --repair`, then synthesize a short Korean sentence with F1-F5 and M1-M5 through `chorus speak`, using each voice's approved baseline speed and volume `0.6`.

Expected: all ten requests synthesize and play without a network TTS service.

- [ ] **Step 4: Run offline and host integration tests**

Disable network access after model installation. Restart the LaunchAgent and speak through direct CLI, a Codex Stop hook, a Claude Stop hook, and one subagent hook per host.

Expected: all paths speak the agent-authored envelope; hook completion is not delayed by playback; invalid and missing envelopes stay silent.

- [ ] **Step 5: Verify settings preservation and uninstall**

Add unrelated custom hooks and skills to disposable Codex and Claude homes, reinstall Chorus twice, modify one Chorus skill, then uninstall.

Expected: unrelated content remains, duplicate Chorus hooks do not appear, the modified Chorus skill is warned about and preserved, and unchanged Chorus-owned content is removed.

- [ ] **Step 6: Run final scope detection and record evidence**

Run GitNexus `detect_changes(scope: compare, base_ref: main)`. Record changed symbols and execution flows in the release checklist. If unavailable, record that limitation and include:

```bash
git diff --check main...HEAD
git diff --stat main...HEAD
git diff --name-status main...HEAD
```

- [ ] **Step 7: Commit release evidence**

```bash
git add docs/release/swift-single-binary-checklist.md README.md
git commit -m "docs: record Swift Chorus release verification"
```

## Final Stop Condition

Stop only when Tasks 1-14 are committed, all Swift tests pass from a clean package state, the real Supertonic model speaks Korean offline, Codex and Claude preserve and deliver the envelope, `otool -L` proves no non-system runtime dependency, unrelated host settings survive install/uninstall, and GitNexus or the documented fallback confirms that only the approved runtime migration is in scope.
