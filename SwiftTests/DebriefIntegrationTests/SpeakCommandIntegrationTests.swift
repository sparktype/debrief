import Foundation
import Testing
@testable import DebriefCore

@Suite("SpeakCommandIntegrationTests")
struct SpeakCommandIntegrationTests {
    @Test func validFieldsSubmitExactlyOnce() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let server = try UnixSocketServer(socketURL: DebriefPaths.forHome(home).socketURL)

        async let received = server.accept()
        try await DirectSpeechCommand.submit(
            text: "직접 발화",
            voice: "M1",
            speed: 1.1,
            volume: 0.7,
            home: home
        )

        #expect(try await received.envelope == SpeechEnvelope(
            v: 1,
            text: "직접 발화",
            voice: "M1",
            speed: 1.1,
            volume: 0.7
        ))
    }

    @Test func invalidFieldsFailBeforeSocketAccess() async {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        await #expect(throws: EnvelopeError.invalidVoice) {
            try await DirectSpeechCommand.submit(
                text: "x", voice: "BAD", speed: 1, volume: 1, home: home
            )
        }
    }

    @Test func unavailableDaemonReturnsTransportFailure() async {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        await #expect(throws: (any Error).self) {
            try await DirectSpeechCommand.submit(
                text: "x", voice: "F1", speed: 1, volume: 1, home: home
            )
        }
    }

    private func temporaryHome() -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "sp-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
