/// Priority for queue admission and mode policy (independent of host hook events).
public enum SpeechPriority: String, Codable, Equatable, Sendable, CaseIterable {
    /// Primary agent turn — always considered for playback (subject to mute / volume ceiling).
    case main
    /// Subagent or background turn — may be suppressed in focus / quiet / night.
    case subagent
}

public protocol SpeechSink: Sendable {
    func submit(_ request: SpeechRequest) async throws
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let envelope: SpeechEnvelope
    public let priority: SpeechPriority
    public let agentType: String?

    public init(
        envelope: SpeechEnvelope,
        priority: SpeechPriority = .main,
        agentType: String? = nil
    ) {
        self.envelope = envelope
        self.priority = priority
        self.agentType = agentType
    }

    public var isMain: Bool { priority == .main }
}
