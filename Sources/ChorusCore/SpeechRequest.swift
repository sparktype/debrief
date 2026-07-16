public protocol SpeechSink: Sendable {
    func submit(_ request: SpeechRequest) async throws
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let envelope: SpeechEnvelope
    public let event: HookEventName
    public let agentType: String?

    public init(envelope: SpeechEnvelope, event: HookEventName, agentType: String?) {
        self.envelope = envelope
        self.event = event
        self.agentType = agentType
    }
}
