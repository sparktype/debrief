import Foundation

public struct HookResult: Sendable {
    public let stdout: Data
    public let submitted: Bool
    /// Human-readable delivery problem for diagnostics / menu bar (nil when healthy).
    public let deliveryError: String?

    public init(stdout: Data, submitted: Bool, deliveryError: String? = nil) {
        self.stdout = stdout
        self.submitted = submitted
        self.deliveryError = deliveryError
    }
}

public struct HookEngine: Sendable {
    private let sink: any SpeechSink

    public init(sink: any SpeechSink) {
        self.sink = sink
    }

    public func handle(_ event: HookEvent, source: HostSource) async -> HookResult {
        switch event.name {
        case .sessionStart, .userPromptSubmit, .subagentStart:
            // Prefer host-provided agent type (Claude --agent / SubagentStart) when present.
            let context = VoiceCatalog.context(for: event.agentType)
            let stdout = (try? HookAdapter.contextOutput(context, source: source, event: event))
                ?? Data("{}".utf8)
            return HookResult(stdout: stdout, submitted: false)

        case .stop, .subagentStop:
            let success = (try? HookAdapter.successOutput(source: source, event: event))
                ?? Data("{}".utf8)
            guard let message = event.lastAssistantMessage,
                  let envelope = SpeechEnvelopeParser.extract(from: message)
            else {
                return HookResult(stdout: success, submitted: false)
            }

            let assigned = VoiceCatalog.assignment(for: event.agentType).voice
            guard envelope.voice == assigned else {
                return HookResult(
                    stdout: success,
                    submitted: false,
                    deliveryError: "보이스 불일치: envelope \(envelope.voice) ≠ 배정 \(assigned)"
                )
            }

            let request = SpeechRequest(
                envelope: envelope,
                event: event.name,
                agentType: event.agentType
            )
            do {
                try await sink.submit(request)
                return HookResult(stdout: success, submitted: true)
            } catch {
                return HookResult(
                    stdout: success,
                    submitted: false,
                    deliveryError: "TTS 전송 실패: \(Self.shortError(error))"
                )
            }
        }
    }

    private static func shortError(_ error: any Error) -> String {
        if let socket = error as? UnixSocketError {
            switch socket {
            case .disconnected:
                return "서비스 소켓 연결 불가"
            case .rejected:
                return "서비스가 요청을 거부함"
            case .payloadTooLarge:
                return "요청이 너무 큼"
            case .invalidFrame:
                return "소켓 프레임 오류"
            case .pathTooLong, .unsafeExistingPath:
                return "소켓 경로 오류"
            case .systemCall(let name, let code):
                return "\(name)(\(code))"
            }
        }
        return String(describing: error)
    }
}
