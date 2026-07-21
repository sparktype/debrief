import Foundation
import Testing
@testable import ChorusCore

@Suite("UnixSocketTests")
struct UnixSocketTests {
    @Test func socketRoundTripUsesUserOnlyPermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appending(path: "cache/chorus.sock")
        let server = try UnixSocketServer(socketURL: socketURL)
        let client = UnixSocketClient(socketURL: socketURL)
        let envelope = SpeechEnvelope(v: 1, text: "완료", voice: "F1", speed: 0.93, volume: 0.6)
        let fixture = SpeechRequest(envelope: envelope, priority: .main, agentType: nil)

        async let received = server.accept()
        try await client.submit(fixture)

        #expect(try await received == fixture)
        #expect(try permissions(at: socketURL) == 0o600)
        #expect(try permissions(at: socketURL.deletingLastPathComponent()) == 0o700)
    }

    @Test func oversizedPayloadIsRejectedBeforeConnect() async {
        let client = UnixSocketClient(socketURL: URL(fileURLWithPath: "/tmp/chorus-missing.sock"))
        let request = SpeechRequest(
            envelope: SpeechEnvelope(
                v: 1,
                text: String(repeating: "x", count: 20_000),
                voice: "F1",
                speed: 1,
                volume: 1
            ),
            priority: .main,
            agentType: nil
        )

        do {
            try await client.submit(request)
            Issue.record("oversized request unexpectedly succeeded")
        } catch let error as UnixSocketError {
            #expect(error == .payloadTooLarge)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func refusesToUnlinkAnExistingRegularFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appending(path: "chorus.sock")
        try Data("owned data".utf8).write(to: socketURL)

        #expect(throws: UnixSocketError.unsafeExistingPath) {
            try UnixSocketServer(socketURL: socketURL)
        }
        #expect(String(decoding: try Data(contentsOf: socketURL), as: UTF8.self) == "owned data")
    }

    @Test func unavailableSocketFailsWithinBoundedRetry() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = UnixSocketClient(socketURL: directory.appending(path: "missing.sock"))
        let request = SpeechRequest(
            envelope: SpeechEnvelope(v: 1, text: "x", voice: "F1", speed: 1, volume: 1),
            priority: .main,
            agentType: nil
        )
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await client.submit(request)
            Issue.record("missing socket unexpectedly succeeded")
        } catch {
            #expect(start.duration(to: clock.now) < .seconds(1))
        }
    }

    @Test func closingServerUnblocksAccept() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try UnixSocketServer(socketURL: directory.appending(path: "chorus.sock"))

        async let stopped: Bool = {
            do {
                _ = try await server.accept()
                return false
            } catch {
                return true
            }
        }()
        await Task.yield()
        await server.close()

        #expect(await stopped)
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "cs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
