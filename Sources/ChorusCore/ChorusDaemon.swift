import Darwin
import Foundation

public enum ChorusDaemonError: Error, Equatable, Sendable {
    case missingRequestSource
}

public protocol SpeechRequestSource: Sendable {
    func accept() async throws -> SpeechRequest
    func close() async
}

public enum DirectSpeechCommand {
    public static func submit(
        text: String,
        voice: String,
        speed: Double,
        volume: Double,
        priority: SpeechPriority = .main,
        home: URL
    ) async throws {
        let envelope = SpeechEnvelope(
            v: 1,
            text: text,
            voice: voice,
            speed: speed,
            volume: volume
        )
        try envelope.validate()
        let request = SpeechRequest(envelope: envelope, priority: priority, agentType: nil)
        try await UnixSocketClient(socketURL: ChorusPaths.forHome(home).socketURL).submit(request)
    }
}

extension UnixSocketServer: SpeechRequestSource {
    public func close() async {
        requestClose()
    }
}

public actor ChorusDaemon {
    private let source: (any SpeechRequestSource)?
    private let queue: SpeechQueue
    private let backend: any TTSBackend
    private let audio: any AudioPlaying
    private let configuration: @Sendable () -> ChorusConfiguration
    /// Records bounded errors for menu diagnostics (component, code, message).
    private let recordError: (@Sendable (String, String, String) -> Void)?
    private var worker: Task<Void, Never>?
    private var active: SpeechRequest?
    private var discardActive = false
    private var shuttingDown = false

    public init(
        source: (any SpeechRequestSource)? = nil,
        queue: SpeechQueue,
        backend: any TTSBackend,
        audio: any AudioPlaying,
        configuration: @escaping @Sendable () -> ChorusConfiguration,
        recordError: (@Sendable (String, String, String) -> Void)? = nil
    ) {
        self.source = source
        self.queue = queue
        self.backend = backend
        self.audio = audio
        self.configuration = configuration
        self.recordError = recordError
    }

    /// Voice ID of the request currently synthesizing/playing, if any (e.g. `F1`, `M3`).
    public var activeVoice: String? {
        active?.envelope.voice
    }

    public func run() async throws {
        guard let source else { throw ChorusDaemonError.missingRequestSource }
        while !shuttingDown, !Task.isCancelled {
            do {
                await submit(try await source.accept())
            } catch is CancellationError {
                break
            } catch {
                if shuttingDown { break }
                // Bad/partial client frames must not tear down the resident accept loop.
                if Self.isRecoverableAcceptError(error) {
                    continue
                }
                throw error
            }
        }
        if !shuttingDown { await shutdown() }
    }

    /// Frame-level client errors that leave the listen socket healthy.
    static func isRecoverableAcceptError(_ error: any Error) -> Bool {
        guard let socketError = error as? UnixSocketError else { return false }
        switch socketError {
        case .invalidFrame, .payloadTooLarge, .rejected:
            return true
        case .disconnected, .pathTooLong, .unsafeExistingPath, .systemCall:
            return false
        }
    }

    @discardableResult
    public func submit(_ request: SpeechRequest) async -> QueueDecision? {
        guard !shuttingDown,
              ModePolicy.admit(
                priority: request.priority,
                requestedVolume: request.envelope.volume,
                configuration: configuration()
              ) != nil else {
            return nil
        }

        if let active,
           await queue.shouldInterruptActive(active: active, incoming: request) {
            discardActive = true
            await audio.stop()
        }
        let decision = await queue.enqueue(request)
        if decision == .accepted, worker == nil {
            worker = Task { await self.consume() }
        } else if decision == .rejectedCapacity {
            recordError?("queue", "capacity", "발화 대기열이 가득 차 요청을 건너뛰었습니다")
        } else if decision == .rejectedDuplicate {
            recordError?("queue", "duplicate", "동일 발화가 짧은 시간 안에 중복되어 건너뛰었습니다")
        }
        return decision
    }

    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await source?.close()
        worker?.cancel()
        worker = nil
        discardActive = true
        await audio.stop()
        active = nil
    }

    private func consume() async {
        while !Task.isCancelled, !shuttingDown {
            let request = await queue.next()
            if Task.isCancelled || shuttingDown { break }
            active = request
            discardActive = false

            do {
                let buffer = try await backend.synthesize(
                    text: request.envelope.text,
                    voice: request.envelope.voice,
                    speed: request.envelope.speed
                )
                if !discardActive,
                   let gain = ModePolicy.admit(
                    priority: request.priority,
                    requestedVolume: request.envelope.volume,
                    configuration: configuration()
                   ) {
                    try await audio.play(buffer, gain: gain)
                }
            } catch {
                // Drop the failed item and continue; surface for menu diagnostics.
                recordError?(
                    "tts",
                    "synthesis_or_playback",
                    "합성 또는 재생에 실패했습니다: \(String(describing: error).prefix(80))"
                )
            }
            active = nil
            discardActive = false
        }
    }
}
