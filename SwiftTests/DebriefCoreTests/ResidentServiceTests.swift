// ResidentService 시작/중지 라이프사이클 단위 테스트
import Foundation
import Testing
@testable import DebriefCore

@Suite("ResidentServiceTests")
struct ResidentServiceTests {
    @Test func startThenStopClearsSocketAndPid() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )

        try await service.start()
        #expect(await service.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))

        await service.stop()
        #expect(await service.isRunning == false)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test func stopKeepingPidLeavesHostPidClearsSocket() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )

        try await service.start()
        #expect(await service.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        // Menu Stop: host process continues — keep pid, drop socket.
        await service.stop(removePid: false)
        #expect(await service.isRunning == false)
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))

        // Restart still works in the same process.
        try await service.start()
        #expect(await service.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
        await service.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test func parkWithoutSocketRecordsTheErrorAndSkipsTheSocket() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DebriefPaths.forHome(home)
        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )

        await #expect(throws: ResidentServiceError.modelUnavailable) {
            try await service.start()
        }
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        try await service.parkWithoutSocket(message: "모델을 사용할 수 없습니다.")
        #expect(await service.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(Diagnostics(home: home).currentError()?.code == "model_unavailable")
        await service.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test func doubleStartThrowsAlreadyRunning() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )
        try await service.start()
        await #expect(throws: ResidentServiceError.alreadyRunning) {
            try await service.start()
        }
        await service.stop()
    }

    @Test func foreignLivePidWithoutSocketThrowsAlreadyRunning() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(
            at: paths.pidURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Simulate another host after menu Stop: live pid, no socket.
        try "4242".write(to: paths.pidURL, atomically: true, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() },
            processExists: { $0 == 4242 }
        )
        await #expect(throws: ResidentServiceError.alreadyRunning) {
            try await service.start()
        }
    }

    @Test func waitUntilStoppedUnblocksAfterStop() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() }
        )
        try await service.start()
        #expect(await service.isRunning)

        let waiter = Task { await service.waitUntilStopped() }
        // Let the waiter enter the poll loop before stopping.
        try await Task.sleep(for: .milliseconds(50))
        await service.stop()
        await waiter.value
        #expect(await service.isRunning == false)
        #expect(await service.consumeRunFailure() == nil)
    }

    @Test func waitUntilStoppedUnblocksOnRunFailureAndSurfacesError() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        nonisolated(unsafe) var heldServer: UnixSocketServer?
        let service = ResidentService(
            home: home,
            modelDirectoryProvider: { _ in home },
            backendFactory: { _ in RecordingBackend() },
            audioFactory: { RecordingAudio() },
            socketFactory: { url in
                let server = try UnixSocketServer(socketURL: url)
                heldServer = server
                return server
            }
        )
        try await service.start()
        #expect(await service.isRunning)

        let waiter = Task { await service.waitUntilStopped() }
        try await Task.sleep(for: .milliseconds(50))
        // Close the accept source without intentional stop — run loop dies with error.
        heldServer?.requestClose()
        await waiter.value
        #expect(await service.isRunning == false)

        let failure = await service.consumeRunFailure()
        #expect(failure != nil)
        #expect(failure as? UnixSocketError == .disconnected)
        #expect(await service.consumeRunFailure() == nil)
    }

    private func temporaryHome() -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "cr-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingBackend: TTSBackend {
    func synthesize(text: String, voice: String, speed: Double) async throws -> PCMBuffer {
        PCMBuffer(sampleRate: 44_100, channels: 1, samples: [0])
    }
}

private actor RecordingAudio: AudioPlaying {
    func play(_ buffer: PCMBuffer, gain: Double) async throws {}
    func stop() async {}
}
