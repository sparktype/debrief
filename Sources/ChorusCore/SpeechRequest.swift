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
    public let lane: SpeechLane
    public let emotion: SpeechEmotion
    public let agentType: String?

    public init(
        envelope: SpeechEnvelope,
        priority: SpeechPriority = .main,
        lane: SpeechLane = .companion,
        emotion: SpeechEmotion = .neutral,
        agentType: String? = nil
    ) {
        self.envelope = envelope
        self.priority = priority
        self.lane = lane
        self.emotion = emotion
        self.agentType = agentType
    }

    public var isMain: Bool { priority == .main }

    private enum CodingKeys: String, CodingKey {
        case envelope, priority, lane, emotion, agentType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envelope = try container.decode(SpeechEnvelope.self, forKey: .envelope)
        priority = try container.decodeIfPresent(SpeechPriority.self, forKey: .priority) ?? .main
        lane = try container.decodeIfPresent(SpeechLane.self, forKey: .lane) ?? .companion
        emotion = try container.decodeIfPresent(SpeechEmotion.self, forKey: .emotion) ?? .neutral
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
    }
}
