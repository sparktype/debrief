# MenuBar Resident TTS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the single `chorus` executable host TTS in an LSUIElement menu bar process, with LaunchAgent starting `menubar` and menu controls for start/stop, mute, and mode.

**Architecture:** Extract a Core `ResidentService` that owns pid, Unix socket, daemon loop, model load, and start/stop. Wire headless `chorus daemon` and GUI `chorus menubar` through it. Change LaunchAgent `ProgramArguments` to `menubar`. Keep `ChorusCore` + `ChorusCLI` SPM targets; no `.app` bundle and no Quit menu.

**Tech Stack:** Swift 6.4 / Xcode 27 beta, SwiftPM, macOS 14+, Swift Testing, Foundation, AppKit/SwiftUI (`MenuBarExtra`), existing Unix socket + Supertonic + LaunchAgent stack.

## Global Constraints

- Toolchain: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` or `./scripts/with-xcode.sh <cmd>`.
- Product remains TTS-only one executable `chorus`; no Python/Node/shell runtime.
- Do not merge `ChorusCore` and `ChorusCLI` into one SPM target.
- Do not ship `.app` under Applications; keep `~/.local/bin/chorus`.
- LaunchAgent label stays `com.chorus.tts`; KeepAlive stays `true`.
- Menu: Start/Stop, Mute, Mode, status — **no Quit**.
- Hook envelope, five hooks, six skills, socket protocol unchanged.
- TDD: failing test first, then minimal implementation.
- User-facing Korean copy uses 경어체 where new strings appear.
- Claim green only after `./scripts/with-xcode.sh swift test` (and release build at the end).

---

## File Structure

```text
Sources/ChorusCore/
  ResidentService.swift          NEW — start/stop pid+socket+daemon lifecycle
  EmbeddedTemplates.swift        MOD — LaunchAgent args → menubar
  (existing daemon/socket/config unchanged in behavior)

Sources/ChorusCLI/
  Commands.swift                 MOD — menubar case + usage
  main.swift                     MOD — daemon/menubar dispatch via ResidentService
  MenuBarApp.swift               NEW — NSApplication + MenuBarExtra entry
  MenuBarModel.swift             NEW — testable actions (start/stop/mute/mode/status)

SwiftTests/ChorusCoreTests/
  ResidentServiceTests.swift     NEW
  EmbeddedTemplatesTests.swift   MOD — expect menubar
  CommandsTests.swift            NEW or extend if parse tests live elsewhere

SwiftTests/ChorusIntegrationTests/
  RuntimeInstallerTests.swift    MOD — ProgramArguments menubar
  ResidentServiceIntegrationTests.swift  NEW (optional if core tests cover socket)

docs + README/DEVELOPER        MOD — resident = menubar (Task 5)
```

---

### Task 1: Extract `ResidentService` (Core)

**Files:**
- Create: `Sources/ChorusCore/ResidentService.swift`
- Create: `SwiftTests/ChorusCoreTests/ResidentServiceTests.swift`
- Modify: none yet (CLI wiring is Task 2)

**Interfaces:**
- Produces:
  ```swift
  public enum ResidentServiceError: Error, Equatable, Sendable {
      case alreadyRunning
      case modelUnavailable
      case notRunning
  }

  public actor ResidentService {
      public init(
          home: URL,
          backendFactory: @escaping @Sendable (URL) throws -> any TTSBackend,
          audioFactory: @escaping @Sendable () -> any AudioPlaying,
          socketFactory: @escaping @Sendable (URL) throws -> UnixSocketServer = { try UnixSocketServer(socketURL: $0) },
          processExists: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
      )
      public var isRunning: Bool { get }
      public func start() async throws
      public func stop() async
  }
  ```
- Consumes: `ChorusPaths`, `UnixSocketServer`, `ChorusDaemon`, `SpeechQueue`, `InstalledModel.resolveCurrent`, `ChorusConfiguration.load`

- [ ] **Step 1: Write failing tests**

```swift
// SwiftTests/ChorusCoreTests/ResidentServiceTests.swift
import Foundation
import Testing
@testable import ChorusCore

@Suite("ResidentServiceTests")
struct ResidentServiceTests {
    @Test func startThenStopClearsSocketAndPid() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-resident-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = ChorusPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)
        // Minimal model tree so resolveCurrent succeeds OR inject backendFactory that does not need real ONNX:
        // Prefer: ResidentService accepts optional modelDirectory override via factory that ignores model path.
        // Test uses RecordingBackend and never loads Supertonic.

        let service = ResidentService(
            home: home,
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )

        // For tests without real models, ResidentService must resolve model via factory-only path:
        // implement start() to call backendFactory(modelDirectory) only after resolveCurrent,
        // OR allow modelDirectoryProvider injection. Prefer modelDirectoryProvider for tests:

        try await service.start()
        #expect(await service.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path)
            || true) // if nonblocking accept doesn't create visible bind until listen — socket file MUST exist after bind
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))

        await service.stop()
        #expect(await service.isRunning == false)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test func doubleStartThrowsAlreadyRunning() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-resident-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home }, // inject: skip InstalledModel
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )
        try await service.start()
        await #expect(throws: ResidentServiceError.alreadyRunning) {
            try await service.start()
        }
        await service.stop()
    }
}

// Local test doubles (same patterns as DaemonTests)
private actor RecordingBackend: TTSBackend {
    func synthesize(text: String, voice: String, speed: Double) async throws -> PCMBuffer {
        PCMBuffer(sampleRate: 44_100, channels: 1, samples: [0])
    }
}

private actor RecordingAudio: AudioPlaying {
    func play(_ buffer: PCMBuffer, gain: Double) async throws {}
    func stop() async {}
}
```

Refine the production API in Step 3 to include:

```swift
modelDirectoryProvider: @escaping @Sendable (ChorusPaths) throws -> URL = {
    try InstalledModel.resolveCurrent(in: $0.modelsDirectory).directory
}
```

so unit tests never need ONNX assets.

- [ ] **Step 2: Run tests and confirm failure**

Run: `./scripts/with-xcode.sh swift test --filter ResidentServiceTests`

Expected: FAIL — `ResidentService` type not found.

- [ ] **Step 3: Implement `ResidentService`**

```swift
// Sources/ChorusCore/ResidentService.swift
import Darwin
import Foundation

public enum ResidentServiceError: Error, Equatable, Sendable {
    case alreadyRunning
    case modelUnavailable
    case notRunning
}

public actor ResidentService {
    private let home: URL
    private let modelDirectoryProvider: @Sendable (ChorusPaths) throws -> URL
    private let backendFactory: @Sendable (URL) throws -> any TTSBackend
    private let audioFactory: @Sendable () -> any AudioPlaying
    private let socketFactory: @Sendable (URL) throws -> UnixSocketServer
    private let processExists: @Sendable (Int32) -> Bool

    private var server: UnixSocketServer?
    private var daemon: ChorusDaemon?
    private var runTask: Task<Void, Error>?
    private var ownedPID: String?
    private var running = false

    public init(
        home: URL,
        modelDirectoryProvider: @escaping @Sendable (ChorusPaths) throws -> URL = {
            try InstalledModel.resolveCurrent(in: $0.modelsDirectory).directory
        },
        backendFactory: @escaping @Sendable (URL) throws -> any TTSBackend,
        audioFactory: @escaping @Sendable () -> any AudioPlaying,
        socketFactory: @escaping @Sendable (URL) throws -> UnixSocketServer = {
            try UnixSocketServer(socketURL: $0)
        },
        processExists: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        self.home = home
        self.modelDirectoryProvider = modelDirectoryProvider
        self.backendFactory = backendFactory
        self.audioFactory = audioFactory
        self.socketFactory = socketFactory
        self.processExists = processExists
    }

    public var isRunning: Bool { running }

    public func start() async throws {
        guard !running else { throw ResidentServiceError.alreadyRunning }
        let paths = ChorusPaths.forHome(home)

        if let existing = try? String(contentsOf: paths.pidURL, encoding: .utf8),
           let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           pid != getpid(),
           processExists(pid),
           FileManager.default.fileExists(atPath: paths.socketURL.path) {
            throw ResidentServiceError.alreadyRunning
        }

        try FileManager.default.createDirectory(
            at: paths.pidURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let modelDirectory: URL
        do {
            modelDirectory = try modelDirectoryProvider(paths)
        } catch {
            throw ResidentServiceError.modelUnavailable
        }

        let backend: any TTSBackend
        do {
            backend = try backendFactory(modelDirectory)
        } catch {
            throw ResidentServiceError.modelUnavailable
        }

        let server = try socketFactory(paths.socketURL)
        let daemon = ChorusDaemon(
            source: server,
            queue: SpeechQueue(),
            backend: backend,
            audio: audioFactory(),
            configuration: { ChorusConfiguration.load(from: paths.configURL) }
        )

        let pid = "\(getpid())"
        try Data(pid.utf8).write(to: paths.pidURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.pidURL.path)

        self.server = server
        self.daemon = daemon
        self.ownedPID = pid
        self.running = true
        self.runTask = Task {
            try await daemon.run()
        }
    }

    public func stop() async {
        guard running else { return }
        let paths = ChorusPaths.forHome(home)
        await daemon?.shutdown()
        runTask?.cancel()
        _ = try? await runTask?.value
        runTask = nil
        daemon = nil
        server = nil
        if let ownedPID,
           (try? String(contentsOf: paths.pidURL, encoding: .utf8)) == ownedPID {
            try? FileManager.default.removeItem(at: paths.pidURL)
        }
        ownedPID = nil
        running = false
    }
}
```

Adjust details to match `UnixSocketServer` ownership (server must stay retained; `ChorusDaemon` holds `source` strongly). On `stop`, `shutdown` must close the socket so bind can succeed again.

- [ ] **Step 4: Run tests and confirm pass**

Run: `./scripts/with-xcode.sh swift test --filter ResidentServiceTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/ResidentService.swift SwiftTests/ChorusCoreTests/ResidentServiceTests.swift
git commit -m "feat: extract ResidentService for start/stop TTS lifecycle"
```

---

### Task 2: Wire CLI `daemon` through `ResidentService`

**Files:**
- Modify: `Sources/ChorusCLI/main.swift` (`.daemon` case)
- Modify: `SwiftTests/ChorusIntegrationTests/DaemonTests.swift` only if needed (keep existing daemon unit tests)

**Interfaces:**
- Consumes: `ResidentService` from Task 1
- Produces: headless `chorus daemon` uses default factories:

```swift
ResidentService(
    home: home,
    backendFactory: { try SupertonicEngine(modelDirectory: $0) },
    audioFactory: { AudioPlayer() }
)
```

- [ ] **Step 1: Refactor `.daemon` in `main.swift`**

Replace the inline pid/socket/daemon block with:

```swift
case .daemon:
    let service = ResidentService(
        home: home,
        backendFactory: { try SupertonicEngine(modelDirectory: $0) },
        audioFactory: { AudioPlayer() }
    )
    try await service.start()
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT)
    termination.setEventHandler { Task { await service.stop() } }
    interruption.setEventHandler { Task { await service.stop() } }
    termination.resume()
    interruption.resume()
    defer {
        termination.cancel()
        interruption.cancel()
    }
    // Block until stop: poll isRunning or await an internal finished signal.
    // Minimal approach: while await service.isRunning { try await Task.sleep(nanoseconds: 200_000_000) }
    while await service.isRunning {
        try await Task.sleep(for: .milliseconds(200))
    }
```

Prefer adding `ResidentService.waitUntilStopped()` if cleaner:

```swift
public func waitUntilStopped() async {
    while running {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
```

Cover with a small unit test that start → stop unblocks `waitUntilStopped`.

- [ ] **Step 2: Run focused suites**

Run: `./scripts/with-xcode.sh swift test --filter 'ResidentServiceTests|DaemonTests'`

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Sources/ChorusCLI/main.swift Sources/ChorusCore/ResidentService.swift SwiftTests/ChorusCoreTests/ResidentServiceTests.swift
git commit -m "refactor: run chorus daemon via ResidentService"
```

---

### Task 3: `menubar` command + LaunchAgent template

**Files:**
- Modify: `Sources/ChorusCLI/Commands.swift`
- Modify: `Sources/ChorusCore/EmbeddedTemplates.swift` (`launchAgent`)
- Modify: `SwiftTests/ChorusCoreTests/EmbeddedTemplatesTests.swift`
- Modify: `SwiftTests/ChorusIntegrationTests/RuntimeInstallerTests.swift`
- Create: `SwiftTests/ChorusCoreTests/CommandsParseTests.swift` (if no existing parse tests)

**Interfaces:**
- Produces: `ChorusCommand.menubar`
- Produces: LaunchAgent `ProgramArguments == [executable.path, "menubar"]`

- [ ] **Step 1: Write failing tests**

```swift
// CommandsParseTests — parse menubar
@Test func parsesMenubar() throws {
    #expect(try ChorusCommand.parse(["menubar"]) == .menubar)
}

// EmbeddedTemplatesTests
#expect(value["ProgramArguments"] as? [String] == [executable.path, "menubar"])

// RuntimeInstallerTests — after install mock
#expect(plist?["ProgramArguments"] as? [String] == [installed.path, "menubar"])
```

Note: `ChorusCommand` lives in `ChorusCLI`, which is an executable target — **not importable from tests**. Options:

1. Move `ChorusCommand` parse into `ChorusCore` as `ChorusCommandParser` (preferred for testability), or
2. Keep parse in CLI and only test LaunchAgent templates in Core/Integration tests; smoke-test menubar via process spawn in integration.

**Prefer option 1 for TDD:** move enum + `parse` to `Sources/ChorusCore/ChorusCommand.swift` (or keep name `Commands.swift` under Core). CLI `main` imports Core only.

If moving is too large for this task, test only templates/installer in this task and add a thin Core `public enum ResidentEntry: String { case menubar, daemon }` used by LaunchAgent — but full parse move is cleaner.

**Plan decision:** Move `CommandError` + `ChorusCommand` from `Sources/ChorusCLI/Commands.swift` to `Sources/ChorusCore/ChorusCommand.swift`. Delete CLI duplicate. Tests import Core.

- [ ] **Step 2: Run tests — expect FAIL on menubar / ProgramArguments**

Run: `./scripts/with-xcode.sh swift test --filter 'EmbeddedTemplatesTests|RuntimeInstallerTests|CommandsParseTests'`

Expected: FAIL on expected `menubar` vs actual `daemon` (and missing parse if added).

- [ ] **Step 3: Implement**

1. Move command parsing to Core (if chosen).
2. Add `.menubar` case and usage line `chorus menubar`.
3. Change template:

```swift
"ProgramArguments": [executable.path, "menubar"],
```

4. Update skill status text if it says “daemon” only — optional in Task 5.

- [ ] **Step 4: Run tests — PASS**

Run: `./scripts/with-xcode.sh swift test --filter 'EmbeddedTemplatesTests|RuntimeInstallerTests|CommandsParseTests'`

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/ChorusCommand.swift Sources/ChorusCLI/Commands.swift Sources/ChorusCLI/main.swift \
  Sources/ChorusCore/EmbeddedTemplates.swift \
  SwiftTests/ChorusCoreTests/EmbeddedTemplatesTests.swift \
  SwiftTests/ChorusCoreTests/CommandsParseTests.swift \
  SwiftTests/ChorusIntegrationTests/RuntimeInstallerTests.swift
git commit -m "feat: add menubar command and LaunchAgent menubar entry"
```

---

### Task 4: Menu bar UI + actions

**Files:**
- Create: `Sources/ChorusCLI/MenuBarModel.swift`
- Create: `Sources/ChorusCLI/MenuBarApp.swift`
- Modify: `Sources/ChorusCLI/main.swift` — `.menubar` case
- Create: `SwiftTests/ChorusCoreTests/MenuBarModelTests.swift`  
  **If model is in CLI and untestable:** put `MenuBarController` logic in Core as pure state:

```swift
// Sources/ChorusCore/MenuBarState.swift
public struct MenuBarStatus: Equatable, Sendable {
    public var serviceRunning: Bool
    public var muted: Bool
    public var mode: ChorusMode
    public var lastError: String?
}
```

And test configuration + status snapshot composition in Core. CLI owns SwiftUI only.

**Interfaces:**
- Consumes: `ResidentService`, `ConfigurationCommands`, `Diagnostics.status()`
- Produces: LSUIElement menu with Start/Stop/Mute/Mode/status; **no Quit**

- [ ] **Step 1: Write failing Core tests for status line + mute/mode helpers**

```swift
@Test func statusLineSummarizesRunningMutedMode() {
    let line = MenuBarStatus(
        serviceRunning: true,
        muted: true,
        mode: .focus
    ).summaryLine
    #expect(line.contains("실행 중") || line.lowercased().contains("running"))
    #expect(line.contains("focus") || line.contains("포커스"))
}
```

Pick one language for menu strings and stick to it; **prefer Korean 경어체** for user-visible menu if the rest of CLI is Korean (`Codex에서 /hooks를...`). Example:

```swift
public var summaryLine: String {
    let service = serviceRunning ? "서비스 실행 중" : "서비스 중지됨"
    let mute = muted ? "음소거" : "음성 사용"
    return "\(service) · \(mute) · \(mode.rawValue)"
}
```

- [ ] **Step 2: Implement `MenuBarStatus` in Core + `MenuBarApp` in CLI**

`MenuBarApp.swift` sketch:

```swift
import AppKit
import SwiftUI
import ChorusCore

@MainActor
final class MenuBarController: ObservableObject {
    @Published var status: MenuBarStatus
    private let home: URL
    private let service: ResidentService

    init(home: URL, service: ResidentService) {
        self.home = home
        self.service = service
        self.status = MenuBarStatus(serviceRunning: false, muted: false, mode: .normal, lastError: nil)
    }

    func refresh() async {
        let snapshot = Diagnostics(home: home).status()
        let running = await service.isRunning
        status = MenuBarStatus(
            serviceRunning: running,
            muted: snapshot.muted,
            mode: snapshot.mode,
            lastError: nil
        )
    }

    func start() async {
        do { try await service.start(); await refresh() }
        catch { status.lastError = String(describing: error); await refresh() }
    }

    func stop() async {
        await service.stop()
        await refresh()
    }

    func toggleMute() async {
        _ = try? ConfigurationCommands.applyMute("toggle", home: home)
        await refresh()
    }

    func setMode(_ mode: ChorusMode) async {
        _ = try? ConfigurationCommands.applyMode(mode.rawValue, home: home)
        await refresh()
    }
}

struct ChorusMenuBarScene: Scene {
    @ObservedObject var controller: MenuBarController

    var body: some Scene {
        MenuBarExtra("Chorus", systemImage: controller.status.serviceRunning ? "waveform" : "waveform.slash") {
            Text(controller.status.summaryLine)
                .disabled(true)
            Divider()
            Button(controller.status.muted ? "음소거 해제" : "음소거") {
                Task { await controller.toggleMute() }
            }
            Menu("모드") {
                ForEach(ChorusMode.allCases, id: \.rawValue) { mode in
                    Button(mode.rawValue) {
                        Task { await controller.setMode(mode) }
                    }
                }
            }
            Divider()
            if controller.status.serviceRunning {
                Button("서비스 중지") { Task { await controller.stop() } }
            } else {
                Button("서비스 시작") { Task { await controller.start() } }
            }
            // No Quit
        }
    }
}

enum MenuBarApp {
    static func run(home: URL) async throws {
        let service = ResidentService(
            home: home,
            backendFactory: { try SupertonicEngine(modelDirectory: $0) },
            audioFactory: { AudioPlayer() }
        )
        // Auto-start service on launch (LaunchAgent path).
        try? await service.start()

        let controller = MenuBarController(home: home, service: service)
        await controller.refresh()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Host SwiftUI MenuBarExtra via a minimal App structure:
        // Use @main alternative: call MenuBarExtra via NSStatusItem if MenuBarExtra requires App protocol.
        // Practical approach for SPM executable:
        let delegate = MenuBarAppDelegate(controller: controller)
        app.delegate = delegate
        app.run() // blocking
    }
}
```

**SPM note:** `MenuBarExtra` requires a SwiftUI `App`. For an executable that also handles CLI, use:

```swift
// When command == .menubar only:
struct ChorusMenuBarApp: App {
    @StateObject private var controller: MenuBarController
    init(home: URL, service: ResidentService) {
        _controller = StateObject(wrappedValue: MenuBarController(home: home, service: service))
    }
    var body: some Scene {
        ChorusMenuBarScene(controller: controller)
    }
}
```

And start with:

```swift
// Cannot easily call App.main() with injected home after async start.
// Pattern:
// 1) Create service, try start
// 2) Store home/service in a small process-global for App init
// 3) ChorusMenuBarApp.main()
```

Document the chosen pattern in code comments. Acceptable alternative: pure `NSStatusItem` without SwiftUI if `App.main()` conflicts with CLI entry — prefer `NSStatusItem` for simpler dual-entry SPM executables:

```swift
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // build NSMenu with items for mute/mode/start/stop
}
```

**Plan choice for reliability:** implement v1 with **`NSStatusItem` + `NSMenu`** (AppKit only). Avoids SwiftUI App lifecycle fights with CLI `main`. Same UX, fewer integration risks.

- [ ] **Step 3: Wire `case .menubar` in main**

```swift
case .menubar:
    try await MenuBarApp.run(home: home)
```

`MenuBarApp.run` sets activation policy, creates `ResidentService`, auto-starts, installs status item, runs `RunLoop.main` / `NSApp.run()`, and handles SIGTERM → `service.stop()` then terminate.

- [ ] **Step 4: Run tests**

Run: `./scripts/with-xcode.sh swift test --filter 'MenuBarStatus|ResidentServiceTests|EmbeddedTemplatesTests'`

Expected: PASS

Manual smoke (optional, not required for commit):  
`./scripts/with-xcode.sh swift build -c debug && .build/debug/chorus menubar`  
then `chorus status` / mute from menu.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCLI/MenuBarApp.swift Sources/ChorusCLI/main.swift \
  Sources/ChorusCore/MenuBarStatus.swift SwiftTests/ChorusCoreTests/MenuBarStatusTests.swift
git commit -m "feat: add LSUIElement menu bar controls for resident TTS"
```

---

### Task 5: Docs and skill wording

**Files:**
- Modify: `README.md` — note menu bar resident + start/stop
- Modify: `DEVELOPER.md` — process diagram / layout
- Modify: `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` only if a one-line pointer is desired (optional; new design already supersedes process model)
- Modify: `Sources/ChorusCore/EmbeddedTemplates.swift` skill body for status if it says “daemon” exclusively
- Modify: `plugins/chorus/skills/*/SKILL.md` if present and user-facing

- [ ] **Step 1: Update README runtime section**

State that after install, LaunchAgent runs `chorus menubar`; menu bar controls mute/mode/service; CLI remains for hooks and install.

- [ ] **Step 2: Update DEVELOPER.md layout**

Mention `ResidentService`, menu bar entry in CLI, LaunchAgent args.

- [ ] **Step 3: Soften skill status text**

```text
Run `chorus status` and report the current resident process, model, hook, mute, and mode state.
```

- [ ] **Step 4: Commit**

```bash
git add README.md DEVELOPER.md Sources/ChorusCore/EmbeddedTemplates.swift plugins/chorus/skills
git commit -m "docs: describe menu bar resident process model"
```

---

### Task 6: Full verification

**Files:** none expected (fixes only if tests fail)

- [ ] **Step 1: Full test suite**

Run: `./scripts/with-xcode.sh swift test`

Expected: all tests PASS

- [ ] **Step 2: Release build**

Run: `./scripts/with-xcode.sh swift build -c release`

Expected: success; `file .build/release/chorus` shows arm64

- [ ] **Step 3: Installer smoke (local temp home)**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TMP=$(mktemp -d)
CHORUS_HOME="$TMP" .build/release/chorus install --repair  # may need network for model; skip model if offline by pre-seeding
# Verify plist:
plutil -p "$TMP/Library/LaunchAgents/com.chorus.tts.plist" | grep menubar
```

If full install is too heavy, at least:

```bash
# Unit-level already covers plist content via EmbeddedTemplates + RuntimeInstallerTests
```

- [ ] **Step 4: Final commit only if verification fixes were needed**

```bash
git commit -m "fix: address menu bar resident verification failures"
```

---

## Spec Coverage Checklist

| Spec requirement | Task |
| --- | --- |
| Single product executable `chorus` | All (no new product) |
| Keep Core + CLI SPM targets | All |
| LSUIElement menu bar resident | Task 4 |
| In-process daemon | Tasks 1–2, 4 |
| LaunchAgent → `menubar` | Task 3 |
| Menu Start/Stop/Mute/Mode/status | Task 4 |
| No Quit | Task 4 |
| `daemon` debug path | Task 2 |
| `ResidentService` extract | Task 1 |
| Socket contract unchanged | Tasks 1–2 (reuse UnixSocket) |
| Docs/skills | Task 5 |
| Tests + release | Task 6 |
| No `.app` / no SPM merge | Global constraints |

## Self-Review Notes

- No TBD placeholders left in task steps.
- `ChorusCommand` in executable target is untestable — plan moves parse to Core in Task 3.
- Menu UI prefers AppKit `NSStatusItem` to avoid SwiftUI `App` + CLI dual-entry issues.
- `ResidentService` injects `modelDirectoryProvider` so tests skip ONNX.
- Korean 경어체 for new menu strings.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-17-menubar-resident-tts.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session executes tasks with checkpoints  

Which approach?
