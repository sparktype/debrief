import Foundation
import Testing
@testable import ChorusCore

@Suite("HookCommandIntegrationTests")
struct HookCommandIntegrationTests {
    @Test func validStopProducesOneSocketRequestAndSuccessJSON() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let server = try UnixSocketServer(socketURL: ChorusPaths.forHome(home).socketURL)
        let input = try fixture("codex-stop.json")

        async let received = server.accept()
        let output = await HookCommandRunner.run(input: input, source: .codex, home: home)

        #expect(String(decoding: output, as: UTF8.self) == "{}")
        #expect(try await received.envelope.text == "Codex 작업을 완료했습니다.")
    }

    @Test func unavailableSocketStillReturnsHostSuccess() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let output = await HookCommandRunner.run(
            input: try fixture("claude-stop.json"),
            source: .claude,
            home: home
        )

        #expect(String(decoding: output, as: UTF8.self) == "{}")
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
