import Foundation

public struct HookResult: Sendable {
    public let stdout: Data
    public let submitted: Bool

    public init(stdout: Data, submitted: Bool) {
        self.stdout = stdout
        self.submitted = submitted
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
            let agentType = event.name == .subagentStart ? event.agentType : nil
            let context = VoiceCatalog.context(for: agentType)
            let stdout = (try? HookAdapter.contextOutput(context, source: source, event: event))
                ?? Data("{}".utf8)
            return HookResult(stdout: stdout, submitted: false)

        case .stop, .subagentStop:
            let success = (try? HookAdapter.successOutput(source: source, event: event))
                ?? Data("{}".utf8)
            guard let message = event.lastAssistantMessage,
                  let envelope = SpeechEnvelopeParser.extract(from: message),
                  envelope.voice == VoiceCatalog.assignment(for: event.agentType).voice
            else {
                return HookResult(stdout: success, submitted: false)
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
                return HookResult(stdout: success, submitted: false)
            }
        }
    }
}
