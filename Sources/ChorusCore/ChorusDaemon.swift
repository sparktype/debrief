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
        let request = SpeechRequest(envelope: envelope, event: .stop, agentType: nil)
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
    private var worker: Task<Void, Never>?
    private var active: SpeechRequest?
    private var discardActive = false
    private var shuttingDown = false

    public init(
        source: (any SpeechRequestSource)? = nil,
        queue: SpeechQueue,
        backend: any TTSBackend,
        audio: any AudioPlaying,
        configuration: @escaping @Sendable () -> ChorusConfiguration
    ) {
        self.source = source
        self.queue = queue
        self.backend = backend
        self.audio = audio
        self.configuration = configuration
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
                throw error
            }
        }
        if !shuttingDown { await shutdown() }
    }

    @discardableResult
    public func submit(_ request: SpeechRequest) async -> QueueDecision? {
        guard !shuttingDown,
              ModePolicy.admit(
                event: request.event,
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
                    event: request.event,
                    requestedVolume: request.envelope.volume,
                    configuration: configuration()
                   ) {
                    try await audio.play(buffer, gain: gain)
                }
            } catch {
                // A failed request is dropped in memory; the daemon continues with the next item.
            }
            active = nil
            discardActive = false
        }
    }
}
