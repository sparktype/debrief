import Foundation
import Testing
@testable import ChorusCore

@Suite("HookCommandIntegrationTests")
struct HookCommandIntegrationTests {
    @Test func stopWithLegacyEnvelopeReturnsSuccessWithoutSocketTraffic() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let input = try fixture("codex-stop.json")

        let output = await HookCommandRunner.run(input: input, source: .codex, home: home)

        #expect(String(decoding: output, as: UTF8.self) == "{}")
        #expect(Diagnostics(home: home).currentError() == nil)
    }

    @Test func unavailableSocketStillReturnsHostSuccessWithoutDiagnostic() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let output = await HookCommandRunner.run(
            input: try fixture("claude-stop.json"),
            source: .claude,
            home: home
        )

        #expect(String(decoding: output, as: UTF8.self) == "{}")
        #expect(Diagnostics(home: home).currentError() == nil)
    }

    @Test func legacyEnvelopeOnStopIsIgnoredWithoutDiagnostic() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let payload = Data("""
        {"hook_event_name":"Stop","session_id":"s","last_assistant_message":"x\\n<!-- chorus:speak {\\"v\\":1,\\"text\\":\\"t\\",\\"voice\\":\\"M2\\",\\"speed\\":1,\\"volume\\":0.8} -->"}
        """.utf8)
        let output = await HookCommandRunner.run(input: payload, source: .claude, home: home)
        #expect(String(decoding: output, as: UTF8.self) == "{}")
        #expect(Diagnostics(home: home).currentError() == nil)
    }

    @Test func sessionStartContextMentionsSpeakNotHtmlEnvelope() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let payload = Data("""
        {"hook_event_name":"SessionStart","session_id":"s","agent_type":"planner"}
        """.utf8)
        let output = await HookCommandRunner.run(input: payload, source: .claude, home: home)
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("speak"))
        #expect(text.contains("M1"))
        #expect(!text.contains("chorus:speak"))
        #expect(!text.contains("<!--"))
    }

    private func temporaryHome() -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "ch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: tests.appending(path: "Fixtures/Hooks/\(name)"))
    }
}
