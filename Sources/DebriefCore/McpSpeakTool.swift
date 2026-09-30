// MCP speak 도구 인자 파싱·검증·UDS 제출
import Foundation

public struct McpSpeakArguments: Equatable, Sendable {
    public let text: String
    public let voice: String
    public let speed: Double
    public let volume: Double
    public let priority: SpeechPriority
    public let lane: SpeechLane
    public let emotion: SpeechEmotion
    /// Host session id. Companion playback uses the rotated voice for this id.
    public let session: String?

    public init(
        text: String,
        voice: String,
        speed: Double,
        volume: Double,
        priority: SpeechPriority = .main,
        lane: SpeechLane = .companion,
        emotion: SpeechEmotion = .neutral,
        session: String? = nil
    ) {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.volume = volume
        self.priority = priority
        self.lane = lane
        self.emotion = emotion
        self.session = session
    }
}

public struct McpToolCallResult: Equatable, Sendable {
    public let isError: Bool
    public let message: String

    public init(isError: Bool, message: String) {
        self.isError = isError
        self.message = message
    }
}

public enum McpSpeakTool {
    public static func parseArguments(_ object: [String: Any]) throws -> McpSpeakArguments {
        guard let text = object["text"] as? String else {
            throw CommandError.usage("speak requires string text")
        }
        guard let voice = object["voice"] as? String else {
            throw CommandError.usage("speak requires string voice")
        }
        let speed = try number(object["speed"], name: "speed")
        let volume = try number(object["volume"], name: "volume")
        let priority = try optionalPriority(object["priority"])
        let lane = try optionalLane(object["lane"])
        let emotion = try optionalEmotion(object["emotion"])
        let session = try optionalSession(object["session"])
        return McpSpeakArguments(
            text: text,
            voice: voice,
            speed: speed,
            volume: volume,
            priority: priority,
            lane: lane,
            emotion: emotion,
            session: session
        )
    }

    public static func execute(
        arguments: McpSpeakArguments,
        sink: any SpeechSink,
        diagnostics: Diagnostics,
        companionVoice: String? = nil
    ) async -> McpToolCallResult {
        // Work lane prefers neutral affect for prosody (design §8.3).
        let emotionForProsody: SpeechEmotion =
            arguments.lane == .work ? .neutral : arguments.emotion
        let biased = EmotionProsody.apply(
            emotion: emotionForProsody,
            speed: arguments.speed,
            volume: arguments.volume
        )
        let voice = resolvedVoice(arguments: arguments, companionVoice: companionVoice)
        let envelope = SpeechEnvelope(
            v: 1,
            text: arguments.text,
            voice: voice,
            speed: biased.speed,
            volume: biased.volume
        )
        do {
            try envelope.validate()
        } catch {
            return McpToolCallResult(isError: true, message: "잘못된 speak 인자입니다.")
        }
        let request = SpeechRequest(
            envelope: envelope,
            priority: arguments.priority,
            lane: arguments.lane,
            emotion: arguments.emotion,
            agentType: nil
        )
        do {
            try await sink.submit(request)
            try? diagnostics.clearCurrentError()
            return McpToolCallResult(isError: false, message: #"{"ok":true}"#)
        } catch {
            let message = shortError(error)
            try? diagnostics.recordError(
                component: "mcp",
                code: "delivery_failed",
                message: "mcp speak: \(message)"
            )
            return McpToolCallResult(isError: true, message: message)
        }
    }

    /// Companion lane plays the session rotation. Work lane keeps the requested role voice.
    static func resolvedVoice(arguments: McpSpeakArguments, companionVoice: String?) -> String {
        guard arguments.lane == .companion,
              let companionVoice,
              VoiceCatalog.allowedVoiceIDs.contains(companionVoice)
        else {
            return arguments.voice
        }
        return companionVoice
    }

    private static func optionalSession(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let raw = value as? String else {
            throw CommandError.usage("speak session must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalPriority(_ value: Any?) throws -> SpeechPriority {
        guard let value else { return .main }
        guard let raw = value as? String,
              let priority = SpeechPriority(rawValue: raw) else {
            throw CommandError.usage("speak priority must be \"main\" or \"subagent\"")
        }
        return priority
    }

    private static func optionalLane(_ value: Any?) throws -> SpeechLane {
        guard let value else { return .companion }
        guard let raw = value as? String,
              let lane = SpeechLane(rawValue: raw) else {
            throw CommandError.usage("speak lane must be \"companion\" or \"work\"")
        }
        return lane
    }

    private static func optionalEmotion(_ value: Any?) throws -> SpeechEmotion {
        guard let value else { return .neutral }
        guard let raw = value as? String,
              let emotion = SpeechEmotion(rawValue: raw) else {
            throw CommandError.usage(
                "speak emotion must be one of: neutral, warm, focused, concerned, relieved, tired"
            )
        }
        return emotion
    }

    private static func number(_ value: Any?, name: String) throws -> Double {
        if let n = value as? NSNumber {
            guard !isBoolean(n) else {
                throw CommandError.usage("speak requires number \(name)")
            }
            return n.doubleValue
        }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        throw CommandError.usage("speak requires number \(name)")
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func shortError(_ error: any Error) -> String {
        if let socket = error as? UnixSocketError {
            switch socket {
            case .disconnected: return "서비스 소켓 연결 불가"
            case .rejected: return "서비스가 요청을 거부함"
            case .payloadTooLarge: return "요청이 너무 큼"
            default: return "소켓 오류"
            }
        }
        return String(describing: error)
    }
}
