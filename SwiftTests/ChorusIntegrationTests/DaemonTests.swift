import Foundation
import Testing
@testable import ChorusCore

@Suite("DaemonTests")
struct DaemonTests {
    @Test func preservesOrderClampsGainAndContinuesAfterSynthesisFailure() async {
        let backend = RecordingBackend(failingText: "bad")
        let audio = RecordingAudio(blockingMarker: nil)
        var configured = ChorusConfiguration.default
        configured.volumeCeilings[ChorusMode.normal.rawValue] = 0.4
        let configuration = configured
        let daemon = ChorusDaemon(
            queue: SpeechQueue(capacity: 8, duplicateWindow: .zero),
            backend: backend,
            audio: audio,
            configuration: { configuration }
        )

        await daemon.submit(request(.stop, "one", volume: 0.9))
        await daemon.submit(request(.stop, "bad", volume: 0.8))
        await daemon.submit(request(.stop, "three", volume: 0.7))
        await backend.waitUntilCount(3)
        await audio.waitUntilCount(2)

        #expect(await backend.texts == ["one", "bad", "three"])
        #expect(await audio.markers == [3, 5])
        #expect(await audio.gains == [0.4, 0.4])
    }

    @Test func mainInterruptsActiveSubagentAndDropsQueuedSubagents() async {
        let backend = RecordingBackend(failingText: nil)
        let audio = RecordingAudio(blockingMarker: 10)
        let daemon = ChorusDaemon(
            queue: SpeechQueue(capacity: 8, duplicateWindow: .zero),
            backend: backend,
            audio: audio,
            configuration: { .default }
        )

        await daemon.submit(request(.subagentStop, "sub-active", volume: 0.5))
        await audio.waitUntilStarted(10)
        await daemon.submit(request(.subagentStop, "sub-queued", volume: 0.5))
        await daemon.submit(request(.stop, "main", volume: 0.8))
        await backend.waitUntilCount(2)
        await audio.waitUntilCount(2)

        #expect(await audio.stopCount == 1)
        #expect(await backend.texts == ["sub-active", "main"])
        #expect(await audio.markers == [10, 4])
    }

    @Test func shutdownStopsAudioAndTerminatesRunLoop() async throws {
        let source = WaitingSource()
        let audio = RecordingAudio(blockingMarker: nil)
        let daemon = ChorusDaemon(
            source: source,
            queue: SpeechQueue(capacity: 8, duplicateWindow: .zero),
            backend: RecordingBackend(failingText: nil),
            audio: audio,
            configuration: { .default }
        )
        let run = Task { try await daemon.run() }
        await source.waitUntilAccepting()

        await daemon.shutdown()
        try await run.value

        #expect(await audio.stopCount == 1)
        #expect(await source.closeCount == 1)
    }

    @Test func recoverableAcceptErrorsDoNotTerminateRunLoop() async throws {
        let good = request(.stop, "after-bad", volume: 0.8)
        let source = SequenceSource(results: [
            .failure(UnixSocketError.invalidFrame),
            .failure(UnixSocketError.payloadTooLarge),
            .success(good),
            .failure(UnixSocketError.disconnected),
        ])
        let backend = RecordingBackend(failingText: nil)
        let daemon = ChorusDaemon(
            source: source,
            queue: SpeechQueue(capacity: 8, duplicateWindow: .zero),
            backend: backend,
            audio: RecordingAudio(blockingMarker: nil),
            configuration: { .default }
        )
        let run = Task { try await daemon.run() }
        await backend.waitUntilCount(1)
        do {
            try await run.value
            Issue.record("expected disconnected after recoverable frames")
        } catch {
            #expect(error as? UnixSocketError == .disconnected)
        }
        #expect(await backend.texts == ["after-bad"])
        #expect(ChorusDaemon.isRecoverableAcceptError(UnixSocketError.invalidFrame))
        #expect(ChorusDaemon.isRecoverableAcceptError(UnixSocketError.payloadTooLarge))
        #expect(!ChorusDaemon.isRecoverableAcceptError(UnixSocketError.disconnected))
    }

    private func request(_ event: HookEventName, _ text: String, volume: Double) -> SpeechRequest {
        SpeechRequest(
            envelope: SpeechEnvelope(v: 1, text: text, voice: "F1", speed: 0.93, volume: volume),
            event: event,
            agentType: event == .subagentStop ? "explore" : nil
        )
    }
}

private actor RecordingBackend: TTSBackend {
    private let failingText: String?
    private(set) var texts: [String] = []

    init(failingText: String?) { self.failingText = failingText }

    func synthesize(text: String, voice: String, speed: Double) async throws -> PCMBuffer {
        texts.append(text)
        if text == failingText { throw TestFailure.expected }
        return PCMBuffer(sampleRate: 44_100, channels: 1, samples: [Float(text.count)])
    }

    func waitUntilCount(_ count: Int) async {
        while texts.count < count { await Task.yield() }
    }
}

private actor RecordingAudio: AudioPlaying {
    private let blockingMarker: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var markers: [Int] = []
    private(set) var gains: [Double] = []
    private(set) var stopCount = 0

    init(blockingMarker: Int?) { self.blockingMarker = blockingMarker }

    func play(_ buffer: PCMBuffer, gain: Double) async throws {
        let marker = buffer.samples.first.map(Int.init) ?? 0
        markers.append(marker)
        gains.append(gain)
        if marker == blockingMarker {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func stop() async {
        stopCount += 1
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted(_ marker: Int) async {
        while !markers.contains(marker) { await Task.yield() }
    }

    func waitUntilCount(_ count: Int) async {
        while markers.count < count { await Task.yield() }
    }
}

private actor WaitingSource: SpeechRequestSource {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var closeCount = 0
    private var accepting = false

    func accept() async throws -> SpeechRequest {
        accepting = true
        await withCheckedContinuation { continuation = $0 }
        throw CancellationError()
    }

    func close() async {
        closeCount += 1
        continuation?.resume()
        continuation = nil
    }

    func waitUntilAccepting() async {
        while !accepting { await Task.yield() }
    }
}

/// Yields a fixed sequence of accept outcomes for daemon resilience tests.
private actor SequenceSource: SpeechRequestSource {
    private var results: [Result<SpeechRequest, Error>]

    init(results: [Result<SpeechRequest, Error>]) {
        self.results = results
    }

    func accept() async throws -> SpeechRequest {
        guard !results.isEmpty else { throw UnixSocketError.disconnected }
        let next = results.removeFirst()
        return try next.get()
    }

    func close() async {}
}

private enum TestFailure: Error { case expected }
