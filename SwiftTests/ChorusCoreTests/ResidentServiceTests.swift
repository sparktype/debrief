// ResidentService 시작/중지 라이프사이클 단위 테스트
import Foundation
import Testing
@testable import ChorusCore

@Suite("ResidentServiceTests")
struct ResidentServiceTests {
    @Test func startThenStopClearsSocketAndPid() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = ChorusPaths.forHome(home)
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
