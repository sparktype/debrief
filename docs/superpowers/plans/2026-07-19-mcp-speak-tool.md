# MCP Speak Tool + Grok Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the HTML speech envelope with a stdio MCP `speak` tool, wire it to the existing menu-bar UDS path, and add Grok as a first-class install host alongside Codex and Claude.

**Architecture:** Hosts spawn `chorus mcp` (thin JSON-RPC stdio server). Tool `speak` validates args, builds `SpeechEnvelope`/`SpeechRequest`, and submits via `UnixSocketClient`. Menu bar `ResidentService` is unchanged. Claude/Codex keep SessionStart/UserPromptSubmit/SubagentStart hooks with MCP-oriented context; Stop/SubagentStop hooks are uninstalled. Grok gets MCP in `~/.grok/config.toml` plus `~/.grok/skills/chorus-speak` (SessionStart stdout is ignored on Grok).

**Tech Stack:** Swift 6.4 / Xcode 27 beta, SwiftPM, macOS 14+ arm64, Swift Testing, Foundation only (no Node). Spec: `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md`.

## Global Constraints

- Toolchain: `./scripts/with-xcode.sh …` or `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- TTS-only single binary; no Python/Node/HTTP MCP listener.
- MCP lives in a **host-spawned** process, not inside the menubar AppKit process.
- No HTML envelope fallback; missing tool call ⇒ silence.
- Tool name `speak`; server name `chorus`; args `text`/`voice`/`speed`/`volume` all required.
- User-facing Korean strings use 경어체.
- TDD: failing test first, then minimal implementation.
- Claim green only after `./scripts/with-xcode.sh swift test` and release build at the end.
- Before editing existing symbols, run GitNexus impact when available; warn on HIGH/CRITICAL.
- Before commit, prefer `detect_changes` when GitNexus is available.

---

## File Structure

```text
Sources/ChorusCore/
  ChorusCommand.swift           MOD — case mcp; install --grok; usage
  HookEvent.swift               MOD — HostSource.grok; hookEvents for install may stay full enum
  VoiceCatalog.swift            MOD — context() → MCP speak instructions
  HookEngine.swift              MOD — drop Stop submit; start events only
  SpeechEnvelopeParser.swift    DEL — product path removed
  McpServer.swift               NEW — stdio JSON-RPC + tools/list + tools/call speak
  McpSpeakTool.swift            NEW — arg parse/validate + UDS submit + diagnostics
  HostInstaller.swift           MOD — MCP merge, Grok TOML, start-only hooks, grok skills
  EmbeddedTemplates.swift       MOD — hookEvents start-only; grok skill; MCP registration text
  InstallManifest.swift         MOD — optional ownedMcp digests if needed (or reuse files/hooks)
  Diagnostics.swift             MOD — grok config readable
  ChorusDaemon.swift            KEEP — DirectSpeechCommand path reused by MCP

Sources/ChorusCLI/
  main.swift                    MOD — .mcp dispatch; install flags --grok

SwiftTests/ChorusCoreTests/
  CommandsParseTests.swift      MOD
  McpServerTests.swift          NEW
  McpSpeakToolTests.swift       NEW
  HookEngineTests.swift         MOD
  VoiceCatalogTests.swift       MOD or extend
  SpeechEnvelopeParserTests.swift DEL or gut → keep SpeechEnvelope.validate tests only
  EmbeddedTemplatesTests.swift  MOD
  HostInstallerTests → move?    keep under Integration

SwiftTests/ChorusIntegrationTests/
  HostInstallerTests.swift      MOD — MCP + grok + start-only hooks
  HookCommandIntegrationTests   MOD — no stop speech
  (optional) McpCommandIntegrationTests.swift NEW

docs/
  README.md, DEVELOPER.md, CLAUDE.md, ONBOARDING.md  MOD
  specs/2026-07-19-mcp-speak-tool-design.md          MOD status → Approved
```

---

### Task 1: Command surface — `mcp` and `--grok`

**Files:**
- Modify: `Sources/ChorusCore/ChorusCommand.swift`
- Modify: `SwiftTests/ChorusCoreTests/CommandsParseTests.swift`
- Modify: `Sources/ChorusCLI/main.swift` (minimal stub for `.mcp` in Task 3; for this task only parse + install flag plumbing if already wired)

**Interfaces:**
- Produces:
  ```swift
  public enum ChorusCommand: Equatable, Sendable {
      case install(codex: Bool, claude: Bool, grok: Bool, repair: Bool)
      case uninstall(codex: Bool, claude: Bool, grok: Bool)
      case menubar
      case hook(source: String)
      case mcp
      case help
  }
  ```
- Consumes: existing `CommandError`

- [ ] **Step 1: Write failing parse tests**

```swift
// SwiftTests/ChorusCoreTests/CommandsParseTests.swift — add:
@Test func parsesMcp() throws {
    #expect(try ChorusCommand.parse(["mcp"]) == .mcp)
}

@Test func mcpRejectsExtraArguments() {
    #expect(throws: CommandError.self) {
        try ChorusCommand.parse(["mcp", "--extra"])
    }
}

@Test func parsesInstallGrokFlag() throws {
    #expect(
        try ChorusCommand.parse(["install", "--grok"])
            == .install(codex: false, claude: false, grok: true, repair: false)
    )
    #expect(
        try ChorusCommand.parse(["install", "--codex", "--claude", "--grok", "--repair"])
            == .install(codex: true, claude: true, grok: true, repair: true)
    )
}

@Test func parsesUninstallGrokFlag() throws {
    #expect(
        try ChorusCommand.parse(["uninstall", "--grok"])
            == .uninstall(codex: false, claude: false, grok: true)
    )
}
```

- [ ] **Step 2: Run tests — expect fail**

```bash
./scripts/with-xcode.sh swift test --filter CommandsParseTests
```

Expected: FAIL (no `.mcp`, no `grok` associated values).

- [ ] **Step 3: Implement parse + usage**

In `ChorusCommand.swift`:

```swift
case install(codex: Bool, claude: Bool, grok: Bool, repair: Bool)
case uninstall(codex: Bool, claude: Bool, grok: Bool)
case mcp

// usageText includes:
//   chorus install [--codex] [--claude] [--grok] [--repair]
//   chorus uninstall [--codex] [--claude] [--grok]
//   mcp                 MCP stdio server (speak tool)
//   hook --source <codex|claude>

// parse:
case "mcp":
    try requireEmpty(tail, command: name)
    return .mcp
case "install":
    try requireOnly(tail, flags: ["--codex", "--claude", "--grok", "--repair"])
    return .install(
        codex: tail.contains("--codex"),
        claude: tail.contains("--claude"),
        grok: tail.contains("--grok"),
        repair: tail.contains("--repair")
    )
case "uninstall":
    try requireOnly(tail, flags: ["--codex", "--claude", "--grok"])
    return .uninstall(
        codex: tail.contains("--codex"),
        claude: tail.contains("--claude"),
        grok: tail.contains("--grok")
    )
```

Update every call site of `.install` / `.uninstall` associated values (compiler will list them): `main.swift` `selectedHosts`, any tests.

```swift
// main.swift
private func selectedHosts(codex: Bool, claude: Bool, grok: Bool) -> Set<HostSource> {
    if !codex, !claude, !grok { return Set(HostSource.allCases) }
    var hosts = Set<HostSource>()
    if codex { hosts.insert(.codex) }
    if claude { hosts.insert(.claude) }
    if grok { hosts.insert(.grok) }
    return hosts
}
```

`HostSource.grok` is added in Task 4; until then, either add a temporary stub enum case in Task 1 or implement Task 1 and Task 4 together. **Prefer adding `case grok` in Task 1** so parse compiles:

```swift
// HookEvent.swift
public enum HostSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case grok
}
```

Stub HostInstaller `switch` cases for `.grok` with `fatalError("TODO")` only if required to compile — better: Task 1 only touches command parse and leaves HostInstaller incomplete compile until Task 4. **Do Task 1 + Task 4 HostSource enum in one commit if needed for green compile.**

- [ ] **Step 4: Run tests — expect pass**

```bash
./scripts/with-xcode.sh swift test --filter CommandsParseTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/ChorusCommand.swift Sources/ChorusCore/HookEvent.swift \
  Sources/ChorusCLI/main.swift SwiftTests/ChorusCoreTests/CommandsParseTests.swift
git commit -m "feat: parse mcp subcommand and install --grok"
```

---

### Task 2: MCP `speak` tool logic (no stdio loop yet)

**Files:**
- Create: `Sources/ChorusCore/McpSpeakTool.swift`
- Create: `SwiftTests/ChorusCoreTests/McpSpeakToolTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct McpSpeakArguments: Equatable, Sendable {
      public let text: String
      public let voice: String
      public let speed: Double
      public let volume: Double
  }

  public enum McpSpeakTool {
      /// Parse JSON object arguments from tools/call.
      public static func parseArguments(_ object: [String: Any]) throws -> McpSpeakArguments
      /// Validate and submit via sink; record diagnostics on failure.
      public static func execute(
          arguments: McpSpeakArguments,
          sink: any SpeechSink,
          diagnostics: Diagnostics
      ) async -> McpToolCallResult
  }

  public struct McpToolCallResult: Equatable, Sendable {
      public let isError: Bool
      public let message: String
  }
  ```
- Consumes: `SpeechEnvelope`, `SpeechRequest`, `SpeechSink`, `Diagnostics`, `HookEventName.stop`

- [ ] **Step 1: Write failing tests**

```swift
// SwiftTests/ChorusCoreTests/McpSpeakToolTests.swift
import Foundation
import Testing
@testable import ChorusCore

@Suite("McpSpeakToolTests")
struct McpSpeakToolTests {
    @Test func parseRequiresAllFields() throws {
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments(["text": "hi"])
        }
        let args = try McpSpeakTool.parseArguments([
            "text": "빌드를 완료했습니다.",
            "voice": "F1",
            "speed": 0.93,
            "volume": 0.85,
        ])
        #expect(args.text == "빌드를 완료했습니다.")
        #expect(args.voice == "F1")
        #expect(args.speed == 0.93)
        #expect(args.volume == 0.85)
    }

    @Test func executeSubmitsValidRequest() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = RecordingSink()
        let args = McpSpeakArguments(text: "완료했습니다.", voice: "F1", speed: 0.93, volume: 0.85)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: sink,
            diagnostics: Diagnostics(home: home)
        )
        #expect(!result.isError)
        #expect(await sink.recorded().count == 1)
        #expect(await sink.recorded().first?.envelope.text == "완료했습니다.")
        #expect(await sink.recorded().first?.event == .stop)
    }

    @Test func executeRejectsBadVoiceWithoutSubmit() async {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = RecordingSink()
        let args = McpSpeakArguments(text: "x", voice: "BAD", speed: 1, volume: 1)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: sink,
            diagnostics: Diagnostics(home: home)
        )
        #expect(result.isError)
        #expect(await sink.recorded().isEmpty)
    }

    @Test func sinkFailureIsErrorAndRecordsDiagnostics() async {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let args = McpSpeakArguments(text: "x", voice: "F1", speed: 1, volume: 0.5)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: RecordingSink(shouldFail: true),
            diagnostics: Diagnostics(home: home)
        )
        #expect(result.isError)
        #expect(result.message.contains("연결") || result.message.localizedCaseInsensitiveContains("fail")
            || !result.message.isEmpty)
        let errURL = ChorusPaths.forHome(home).lastErrorURL
        #expect(FileManager.default.fileExists(atPath: errURL.path))
    }
}
```

Use existing `RecordingSink` from `HookTestSupport.swift`. If `Diagnostics` / `lastErrorURL` names differ, match `ChorusPaths` and `Diagnostics.recordError` API already in the repo.

- [ ] **Step 2: Run — expect fail**

```bash
./scripts/with-xcode.sh swift test --filter McpSpeakToolTests
```

- [ ] **Step 3: Implement `McpSpeakTool.swift`**

```swift
import Foundation

public struct McpSpeakArguments: Equatable, Sendable {
    public let text: String
    public let voice: String
    public let speed: Double
    public let volume: Double

    public init(text: String, voice: String, speed: Double, volume: Double) {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.volume = volume
    }
}

public struct McpToolCallResult: Equatable, Sendable {
    public let isError: Bool
    public let message: String

    public init(isError: Bool, message: String) {
        self.isError = isError
        self.message = message
    }
}

public enum McpSpeakTool {
    public static func parseArguments(_ object: [String: Any]) throws -> McpSpeakArguments {
        guard let text = object["text"] as? String else {
            throw CommandError.usage("speak requires string text")
        }
        guard let voice = object["voice"] as? String else {
            throw CommandError.usage("speak requires string voice")
        }
        let speed = try number(object["speed"], name: "speed")
        let volume = try number(object["volume"], name: "volume")
        return McpSpeakArguments(text: text, voice: voice, speed: speed, volume: volume)
    }

    public static func execute(
        arguments: McpSpeakArguments,
        sink: any SpeechSink,
        diagnostics: Diagnostics
    ) async -> McpToolCallResult {
        let envelope = SpeechEnvelope(
            v: 1,
            text: arguments.text,
            voice: arguments.voice,
            speed: arguments.speed,
            volume: arguments.volume
        )
        do {
            try envelope.validate()
        } catch {
            return McpToolCallResult(isError: true, message: "잘못된 speak 인자입니다.")
        }
        let request = SpeechRequest(envelope: envelope, event: .stop, agentType: nil)
        do {
            try await sink.submit(request)
            try? diagnostics.clearCurrentError()
            return McpToolCallResult(isError: false, message: #"{"ok":true}"#)
        } catch {
            let message = shortError(error)
            try? diagnostics.recordError(
                component: "mcp",
                code: "delivery_failed",
                message: "mcp speak: \(message)"
            )
            return McpToolCallResult(isError: true, message: message)
        }
    }

    private static func number(_ value: Any?, name: String) throws -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        throw CommandError.usage("speak requires number \(name)")
    }

    private static func shortError(_ error: any Error) -> String {
        if let socket = error as? UnixSocketError {
            switch socket {
            case .disconnected: return "서비스 소켓 연결 불가"
            case .rejected: return "서비스가 요청을 거부함"
            case .payloadTooLarge: return "요청이 너무 큼"
            default: return "소켓 오류"
            }
        }
        return String(describing: error)
    }
}
```

- [ ] **Step 4: Run — expect pass**

```bash
./scripts/with-xcode.sh swift test --filter McpSpeakToolTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/McpSpeakTool.swift SwiftTests/ChorusCoreTests/McpSpeakToolTests.swift
git commit -m "feat: validate and submit MCP speak tool arguments"
```

---

### Task 3: Stdio MCP server + `chorus mcp` entry

**Files:**
- Create: `Sources/ChorusCore/McpServer.swift`
- Create: `SwiftTests/ChorusCoreTests/McpServerTests.swift`
- Modify: `Sources/ChorusCLI/main.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct McpServer: Sendable {
      public init(
          home: URL,
          sink: (any SpeechSink)? = nil, // default UnixSocketClient
          input: FileHandle = .standardInput,
          output: FileHandle = .standardOutput
      )
      /// Run until stdin EOF. Uses MCP Content-Length framing.
      public func run() async
  }
  ```
- Consumes: `McpSpeakTool`, `UnixSocketClient`, `Diagnostics`

**Framing:** MCP stdio uses LSP-style headers:

```text
Content-Length: <byte count>\r\n
\r\n
{json}
```

- [ ] **Step 1: Write failing protocol tests** (in-memory, no real process)

Prefer testing pure handlers rather than full FileHandle:

```swift
// In McpServer.swift expose for tests:
public enum McpJSONRPC {
    public static func handle(
        request: [String: Any],
        speak: @escaping @Sendable ([String: Any]) async -> McpToolCallResult
    ) async -> [String: Any]?
}
```

```swift
// SwiftTests/ChorusCoreTests/McpServerTests.swift
@Suite("McpServerTests")
struct McpServerTests {
    @Test func initializeReturnsServerInfo() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "t", "version": "0"]],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in McpToolCallResult(isError: true, message: "no") })
        let result = res?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String != nil)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "chorus")
    }

    @Test func toolsListContainsSpeak() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in .init(isError: false, message: "") })!
        let tools = (res["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains(where: { ($0["name"] as? String) == "speak" }) == true)
    }

    @Test func toolsCallSpeakInvokesHandler() async {
        var seen: [String: Any]?
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "speak",
                "arguments": [
                    "text": "hi", "voice": "F1", "speed": 1.0, "volume": 0.5,
                ],
            ],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { args in
            seen = args
            return McpToolCallResult(isError: false, message: #"{"ok":true}"#)
        })!
        #expect(seen?["text"] as? String == "hi")
        let result = res["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
    }

    @Test func notificationsReturnNilResponse() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in .init(isError: false, message: "") })
        #expect(res == nil)
    }
}
```

- [ ] **Step 2: Run — expect fail**

```bash
./scripts/with-xcode.sh swift test --filter McpServerTests
```

- [ ] **Step 3: Implement `McpServer.swift` + wire main**

Implement `McpJSONRPC.handle` methods:

| method | behavior |
| --- | --- |
| `initialize` | result with `protocolVersion`, `capabilities: { tools: {} }`, `serverInfo: { name: "chorus", version: ChorusVersion.current }` |
| `notifications/initialized` | nil response |
| `tools/list` | one tool `speak` with JSON Schema for four required properties |
| `tools/call` | name must be `speak`; parse arguments object; call speak closure; return MCP content array + `isError` |
| `ping` | empty result `{}` |
| unknown | JSON-RPC error `-32601` |

`tools/call` result shape:

```json
{
  "content": [{ "type": "text", "text": "{\"ok\":true}" }],
  "isError": false
}
```

Stdio loop (`McpServer.run`):

1. Read headers until blank line; parse `Content-Length`
2. Read body bytes; JSONSerialization
3. Handle; if response non-nil, write Content-Length frame to stdout
4. Repeat until EOF

`main.swift`:

```swift
case .mcp:
    let paths = ChorusPaths.forHome(home)
    let sink = UnixSocketClient(socketURL: paths.socketURL)
    await McpServer(home: home, sink: sink).run()
```

Ensure `@main` non-menubar path can run async mcp until EOF (existing `NonMenubarRunner` run loop is fine).

- [ ] **Step 4: Run — expect pass**

```bash
./scripts/with-xcode.sh swift test --filter McpServerTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/McpServer.swift Sources/ChorusCLI/main.swift \
  SwiftTests/ChorusCoreTests/McpServerTests.swift
git commit -m "feat: add stdio MCP server with speak tool"
```

---

### Task 4: HostInstaller — start-only hooks + MCP registration + Grok

**Files:**
- Modify: `Sources/ChorusCore/HostInstaller.swift`
- Modify: `Sources/ChorusCore/EmbeddedTemplates.swift`
- Modify: `Sources/ChorusCore/Diagnostics.swift`
- Modify: `SwiftTests/ChorusIntegrationTests/HostInstallerTests.swift`
- Modify: `SwiftTests/ChorusCoreTests/EmbeddedTemplatesTests.swift`
- Modify: `Sources/ChorusCore/InstallManifest.swift` if adding `ownedMcp: [OwnedInstalledFile]` or store MCP ownership as `OwnedInstalledFile` with synthetic paths like `mcp:codex:chorus`

**Interfaces:**
- Produces:
  ```swift
  // EmbeddedTemplates
  public static let hookEvents: [HookEventName] = [
      .sessionStart, .userPromptSubmit, .subagentStart,
  ]
  public static func mcpRegistration(executable: URL) -> [String: Any] // JSON hosts
  public static func grokMcpTomlFragment(executable: URL) -> String
  public static func grokSpeakSkillMarkdown(executable: URL) -> String
  // skillNames for claude/codex still ["setup"]; grok also installs chorus-speak
  ```
- Consumes: `HostSource` including `.grok`

- [ ] **Step 1: Write failing installer + template tests**

```swift
// EmbeddedTemplatesTests — replace five-hook expectation:
@Test func templatesInstallStartHooksOnlyAndMcpMeta() throws {
    let executable = URL(fileURLWithPath: "/Applications/Chorus.app/Contents/MacOS/chorus")
    #expect(Set(EmbeddedTemplates.hookEvents.map(\.rawValue)) == [
        "SessionStart", "UserPromptSubmit", "SubagentStart",
    ])
    let mcp = EmbeddedTemplates.mcpRegistration(executable: executable)
    #expect(mcp["command"] as? String == executable.path)
    #expect(mcp["args"] as? [String] == ["mcp"])
    let toml = EmbeddedTemplates.grokMcpTomlFragment(executable: executable)
    #expect(toml.contains("[mcp_servers.chorus]"))
    #expect(toml.contains(executable.path))
    #expect(toml.contains(#""mcp""#) || toml.contains("mcp"))
    let skill = EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable)
    #expect(skill.contains("chorus__speak") || skill.contains("`speak`"))
    #expect(!skill.contains("chorus:speak"))
}

// HostInstallerTests — key cases:
@Test func installMergesMcpAndStartHooksOnly() throws {
    let home = temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appending(path: ".codex/hooks.json")
    try writeJSON([
        "mcpServers": ["keep": ["command": "unrelated"]],
        "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "keep"]]]]],
    ], to: codex)
    // pre-create grok config with foreign server
    let grokConfig = home.appending(path: ".grok/config.toml")
    try FileManager.default.createDirectory(at: grokConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    [mcp_servers.other]
    command = "/bin/echo"
    enabled = true
    """.utf8).write(to: grokConfig)

    let installer = HostInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/chorus-bin"))
    _ = try installer.install(hosts: Set(HostSource.allCases))

    let codexJSON = try json(at: codex)
    let mcpServers = try #require(codexJSON["mcpServers"] as? [String: Any])
    #expect(mcpServers["keep"] != nil)
    #expect(mcpServers["chorus"] != nil)
    let hooks = try #require(codexJSON["hooks"] as? [String: Any])
    #expect(hooks["SessionStart"] != nil)
    #expect(hooks["Stop"] == nil)
    #expect(hooks["SubagentStop"] == nil)

    let toml = try String(contentsOf: grokConfig, encoding: .utf8)
    #expect(toml.contains("[mcp_servers.other]"))
    #expect(toml.contains("[mcp_servers.chorus]"))
    #expect(FileManager.default.fileExists(
        atPath: home.appending(path: ".grok/skills/chorus-speak/SKILL.md").path
    ))
}

@Test func uninstallRemovesChorusMcpPreservesOthers() throws {
    let home = temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HostInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/chorus-bin"))
    try installer.install(hosts: Set(HostSource.allCases))
    // ensure foreign mcp remains after install path that also had keep — re-add if needed
    _ = try installer.uninstall(hosts: Set(HostSource.allCases))
    // codex mcpServers.chorus gone; grok [mcp_servers.chorus] gone; skill removed if unchanged
}
```

Also update `assertInstalledHooks` to only assert the three start events.

- [ ] **Step 2: Run — expect fail**

```bash
./scripts/with-xcode.sh swift test --filter EmbeddedTemplatesTests
./scripts/with-xcode.sh swift test --filter HostInstallerTests
```

- [ ] **Step 3: Implement**

**EmbeddedTemplates:**

```swift
public static let hookEvents: [HookEventName] = [
    .sessionStart, .userPromptSubmit, .subagentStart,
]

public static func mcpRegistration(executable: URL) -> [String: Any] {
    [
        "command": executable.path,
        "args": ["mcp"],
    ]
}

public static func grokMcpTomlFragment(executable: URL) -> String {
    """
    [mcp_servers.chorus]
    command = "\(tomlString(executable.path))"
    args = ["mcp"]
    enabled = true
    startup_timeout_sec = 15
    tool_timeout_sec = 10
    """
}

public static func grokSpeakSkillMarkdown(executable: URL) -> String {
    """
    ---
    name: chorus-speak
    description: Speak a short finish summary through local Chorus TTS via MCP tool chorus__speak. Use at end of a turn when a spoken one- or two-sentence summary helps.
    ---

    # Chorus speak

    When you finish a turn that deserves a spoken summary, call the MCP tool on server `chorus`:

    - Grok qualified name: `chorus__speak` (via `search_tool` / `use_tool` if required)
    - Required arguments: `text`, `voice`, `speed`, `volume`
    - Default main voice: `F1`, speed near `0.93`, volume near `0.85`
    - Do **not** put HTML comments or JSON speech metadata in the assistant message body.
    - Mute/mode are controlled only from the Chorus menu bar.

    Binary: `\(executable.path)`.
    """
}
```

Update setup skill body to mention MCP + Grok (`config.toml`, `/mcps`).

**HostInstaller install loop:**

For `.codex` / `.claude`:

1. Merge start hooks only (existing loop over `EmbeddedTemplates.hookEvents`).
2. Merge `root["mcpServers"]` dictionary; set `mcpServers["chorus"] = EmbeddedTemplates.mcpRegistration(...)`.
3. Record ownership: digest of the chorus mcp object; on uninstall remove only if digest matches.
4. Skills: setup only (existing).

For `.grok`:

1. **Do not** write Claude-style hooks JSON for speech context (v1).
2. Merge TOML: load `~/.grok/config.toml` as text; replace or insert owned block between markers:

   ```toml
   # BEGIN chorus-mcp
   [mcp_servers.chorus]
   ...
   # END chorus-mcp
   ```

   Prefer marker-based ownership for safe uninstall. If markers missing but table exists with matching digest of fragment, still owned.

3. Write `~/.grok/skills/chorus-speak/SKILL.md` with digest ownership (same as other skills).
4. Optional: still install `~/.grok/skills` setup variant or rely on claude-compatible setup — install `chorus-setup` under `~/.grok/skills/` only if useful; minimum is `chorus-speak`.

**TOML merge algorithm (deterministic):**

```swift
enum GrokConfigToml {
    static let begin = "# BEGIN chorus-mcp"
    static let end = "# END chorus-mcp"

    static func upsert(existing: String, fragment: String) -> String {
        let block = "\(begin)\n\(fragment.trimmingCharacters(in: .newlines))\n\(end)\n"
        if let range = existing.range(of: #"\#(begin)[\s\S]*?\#(end)\n?"#, options: .regularExpression) {
            return existing.replacingCharacters(in: range, with: block)
        }
        var base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { base += "\n\n" }
        return base + block
    }

    static func removeOwned(_ existing: String) -> String {
        existing.replacingOccurrences(
            of: #"\#(begin)[\s\S]*?\#(end)\n?"#,
            with: "",
            options: .regularExpression
        )
    }
}
```

**Uninstall:** remove start hooks by digest (existing); remove `mcpServers["chorus"]` if owned; `GrokConfigToml.removeOwned`; remove unchanged grok skill files.

**Diagnostics:** add grok path:

```swift
HostSource.grok.rawValue: settingsReadableToml(paths.home.appending(path: ".grok/config.toml"))
```

For grok, “readable” means file missing (ok) or UTF-8 readable (ok); do not require JSON.

- [ ] **Step 4: Run installer tests**

```bash
./scripts/with-xcode.sh swift test --filter HostInstallerTests
./scripts/with-xcode.sh swift test --filter EmbeddedTemplatesTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/HostInstaller.swift Sources/ChorusCore/EmbeddedTemplates.swift \
  Sources/ChorusCore/Diagnostics.swift Sources/ChorusCore/InstallManifest.swift \
  SwiftTests/ChorusIntegrationTests/HostInstallerTests.swift \
  SwiftTests/ChorusCoreTests/EmbeddedTemplatesTests.swift
git commit -m "feat: install MCP registration and Grok host support"
```

---

### Task 5: Hook context cutover — drop Stop speech path

**Files:**
- Modify: `Sources/ChorusCore/VoiceCatalog.swift`
- Modify: `Sources/ChorusCore/HookEngine.swift`
- Modify: `SwiftTests/ChorusCoreTests/HookEngineTests.swift`
- Modify: `SwiftTests/ChorusCoreTests/VoiceCatalogTests.swift` (create if missing)
- Modify fixtures under `SwiftTests/Fixtures/Hooks/` only if still decoded for adapter tests
- Modify: `SwiftTests/ChorusIntegrationTests/HookCommandIntegrationTests.swift`

**Interfaces:**
- Produces: `VoiceCatalog.context(for:)` text with MCP instructions; no `<!-- chorus:speak`
- `HookEngine.handle` for `.stop` / `.subagentStop`: return success `{}`, **never** submit

- [ ] **Step 1: Write failing tests**

```swift
@Test func contextMentionsSpeakToolNotHtmlEnvelope() {
    let text = VoiceCatalog.context(for: "planner")
    #expect(text.contains("speak"))
    #expect(text.contains("M1"))
    #expect(!text.contains("chorus:speak"))
    #expect(!text.contains("<!--"))
}

@Test func stopDoesNotSubmitEvenWithLegacyEnvelope() async {
    let sink = RecordingSink()
    let event = HookEvent(
        name: .stop,
        sessionID: "s",
        turnID: nil,
        agentType: nil,
        lastAssistantMessage:
            "<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"F1\",\"speed\":0.93,\"volume\":0.85} -->"
    )
    let result = await HookEngine(sink: sink).handle(event, source: .claude)
    #expect(!result.submitted)
    #expect(await sink.recorded().isEmpty)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
}
```

Update/remove tests: `validStopSubmitsExactlyOnce`, `invalidOrMismatchedEnvelopeIsSuccessfulNoOp`, `sinkFailureDoesNotAffectAgentCompletion` — replace with Stop-no-op and context assertions.

- [ ] **Step 2: Run — expect fail**

```bash
./scripts/with-xcode.sh swift test --filter HookEngineTests
./scripts/with-xcode.sh swift test --filter VoiceCatalog
```

- [ ] **Step 3: Implement**

```swift
// VoiceCatalog.context
return """
When you finish this turn, call the Chorus MCP tool `speak` once with a one- or two-sentence spoken summary. \
Required arguments: text, voice, speed, volume. \
Use voice \(assignment.voice) (\(assignment.name)); choose speed from 0.7 through 2.0 (baseline \(assignment.baselineSpeed)) \
and volume from 0.0 through 1.0 (typical 0.85). \
Keep text at 800 characters or fewer. \
Do not put HTML comments, JSON speech metadata, or chorus:speak markers in the assistant message body.
"""

// HookEngine
public func handle(_ event: HookEvent, source: HostSource) async -> HookResult {
    switch event.name {
    case .sessionStart, .userPromptSubmit, .subagentStart:
        let context = VoiceCatalog.context(for: event.agentType)
        let stdout = (try? HookAdapter.contextOutput(context, source: source, event: event))
            ?? Data("{}".utf8)
        return HookResult(stdout: stdout, submitted: false)
    case .stop, .subagentStop:
        let success = (try? HookAdapter.successOutput(source: source, event: event))
            ?? Data("{}".utf8)
        return HookResult(stdout: success, submitted: false)
    }
}
```

- [ ] **Step 4: Run — expect pass**

```bash
./scripts/with-xcode.sh swift test --filter HookEngineTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ChorusCore/VoiceCatalog.swift Sources/ChorusCore/HookEngine.swift \
  SwiftTests/ChorusCoreTests/HookEngineTests.swift \
  SwiftTests/ChorusCoreTests/VoiceCatalogTests.swift \
  SwiftTests/ChorusIntegrationTests/HookCommandIntegrationTests.swift
git commit -m "feat: retarget hooks to MCP speak; stop envelope extraction"
```

---

### Task 6: Remove `SpeechEnvelopeParser` product surface

**Files:**
- Delete: `Sources/ChorusCore/SpeechEnvelopeParser.swift` (if no remaining refs)
- Modify: `SwiftTests/ChorusCoreTests/SpeechEnvelopeParserTests.swift` → rename to `SpeechEnvelopeValidationTests.swift` keeping only `validate()` cases; remove extract tests
- Grep and remove remaining product references

- [ ] **Step 1: Grep**

```bash
rg -n "SpeechEnvelopeParser|chorus:speak" Sources SwiftTests README.md DEVELOPER.md CLAUDE.md ONBOARDING.md
```

- [ ] **Step 2: Delete parser; keep envelope validate tests**

Move `rejectsUnsafeTextAndNumbers` onto direct `SpeechEnvelope.validate` tests. Delete extract tests.

- [ ] **Step 3: Build/test**

```bash
./scripts/with-xcode.sh swift test --filter SpeechEnvelope
```

- [ ] **Step 4: Commit**

```bash
git add -A Sources/ChorusCore/SpeechEnvelopeParser.swift \
  SwiftTests/ChorusCoreTests/SpeechEnvelopeParserTests.swift \
  SwiftTests/ChorusCoreTests/SpeechEnvelopeValidationTests.swift
git commit -m "refactor: remove HTML speech envelope parser"
```

---

### Task 7: Docs + design status + plugin templates

**Files:**
- Modify: `README.md`, `DEVELOPER.md`, `CLAUDE.md`, `ONBOARDING.md`
- Modify: `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` — Status: **Approved**
- Modify: `plugins/chorus/hooks/*` if they still show five hooks / envelope
- Modify: `Sources/ChorusCore/EmbeddedTemplates.swift` setup skill (if not done)

- [ ] **Step 1: Rewrite user-facing speech contract**

README section becomes:

```markdown
## Agent speech contract

Agents call the Chorus MCP tool `speak` (server `chorus`) once per turn:

| Field | Required | Notes |
| text | yes | ≤ 800 chars spoken summary |
| voice | yes | F1…F5, M1…M5 |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 |

Do not put speech JSON or HTML comments in the chat body. Install registers MCP for Codex, Claude Code, and Grok.
```

CLAUDE.md hook flow diagram: MCP path; remove envelope example.

DEVELOPER.md: process model includes `chorus mcp`; hosts table includes Grok paths.

- [ ] **Step 2: Commit**

```bash
git add README.md DEVELOPER.md CLAUDE.md ONBOARDING.md \
  docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md plugins/
git commit -m "docs: MCP speak contract and Grok host"
```

---

### Task 8: Full verification

- [ ] **Step 1: Full test suite**

```bash
./scripts/with-xcode.sh swift test
```

Expected: all tests pass.

- [ ] **Step 2: Release build**

```bash
./scripts/with-xcode.sh swift build -c release
file .build/release/chorus
otool -L .build/release/chorus | head
```

Expected: arm64 executable; no unexpected non-system dylibs beyond known ONNX packaging.

- [ ] **Step 3: Manual smoke (local)**

```bash
# Terminal A: ensure menubar/service running (or install --repair)
# Terminal B:
printf '%s' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' | \
  # Prefer a tiny Swift test or script that uses Content-Length framing.
```

Implement a one-shot integration test if manual framing is painful:

```swift
// Optional: McpFramingTests round-trip encode/decode Content-Length
```

Smoke checklist:

1. `speak` tool with menubar up → audio  
2. Chat body has no `chorus:speak`  
3. Temp HOME install includes grok TOML markers + skill  
4. Uninstall removes owned MCP only  

- [ ] **Step 4: Final commit if smoke fixes needed**

```bash
git commit -m "test: MCP framing and install smoke coverage"
```

---

## Spec Coverage Checklist

| Spec section | Task |
| --- | --- |
| MCP tool `speak`, four required args | 2, 3 |
| `chorus mcp` stdio | 3 |
| UDS submit, ACK-only | 2 |
| No envelope / no Stop speech | 5, 6 |
| Start hooks retargeted | 5 |
| Codex/Claude MCP merge | 4 |
| Grok TOML + skill | 4 |
| install `--grok` | 1, 4 |
| Diagnostics mcp component | 2 |
| Docs | 7 |
| No Node/HTTP MCP | global + 3 |
| Full test + release | 8 |

## Placeholder / consistency review

- Tool name consistently `speak`; server `chorus`; Grok skill documents `chorus__speak`.
- `HostSource.grok` introduced early enough for compile.
- `SpeechRequest.event` remains `.stop` for queue priority from MCP (not a user hook).
- Hook enum still contains Stop cases for decoding old events / request priority; install set does not.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-19-mcp-speak-tool.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session executes tasks with checkpoints  

Which approach?
