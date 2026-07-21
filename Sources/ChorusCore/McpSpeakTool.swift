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

    public init(
        text: String,
        voice: String,
        speed: Double,
        volume: Double,
        priority: SpeechPriority = .main,
        lane: SpeechLane = .companion,
        emotion: SpeechEmotion = .neutral
    ) {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.volume = volume
        self.priority = priority
        self.lane = lane
        self.emotion = emotion
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
        return McpSpeakArguments(
            text: text,
            voice: voice,
            speed: speed,
            volume: volume,
            priority: priority,
            lane: lane,
            emotion: emotion
        )
    }

    public static func execute(
        arguments: McpSpeakArguments,
        sink: any SpeechSink,
        diagnostics: Diagnostics
    ) async -> McpToolCallResult {
        // Work lane prefers neutral affect for prosody (design §8.3).
        let emotionForProsody: SpeechEmotion =
            arguments.lane == .work ? .neutral : arguments.emotion
        let biased = EmotionProsody.apply(
            emotion: emotionForProsody,
            speed: arguments.speed,
            volume: arguments.volume
        )
        let envelope = SpeechEnvelope(
            v: 1,
            text: arguments.text,
            voice: arguments.voice,
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
