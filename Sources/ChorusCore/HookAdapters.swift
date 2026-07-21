import Foundation

public enum HookAdapterError: Error, Equatable, Sendable {
    case invalidJSON
    case missingEventName
    case unsupportedEvent(String)
    case missingSessionID
}

public enum HookAdapter {
    public static func decode(_ data: Data, source: HostSource) throws -> HookEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            throw HookAdapterError.invalidJSON
        }

        guard let rawEvent = string(
            in: payload,
            keys: ["hook_event_name", "hookEventName", "event_name", "eventName"]
        ) else {
            throw HookAdapterError.missingEventName
        }
        guard let eventName = HookEventName(rawValue: rawEvent) else {
            throw HookAdapterError.unsupportedEvent(rawEvent)
        }

        let sessionKeys: [String]
        switch source {
        case .codex:
            sessionKeys = ["session_id", "sessionId", "conversation_id", "conversationId"]
        case .claude, .grok:
            sessionKeys = ["session_id", "sessionId"]
        }
        guard let sessionID = string(in: payload, keys: sessionKeys), !sessionID.isEmpty else {
            throw HookAdapterError.missingSessionID
        }

        return HookEvent(
            name: eventName,
            sessionID: sessionID,
            turnID: string(in: payload, keys: ["turn_id", "turnId"]),
            // Claude SubagentStart may use agent_type; some hosts send subagent_type / agent_name.
            agentType: string(in: payload, keys: [
                "agent_type", "agentType",
                "subagent_type", "subagentType",
                "agent_name", "agentName",
            ]),
            lastAssistantMessage: string(in: payload, keys: [
                "last_assistant_message", "lastAssistantMessage",
            ])
        )
    }

    public static func contextOutput(
        _ context: String,
        source: HostSource,
        event: HookEvent
    ) throws -> Data {
        let output: [String: Any]
        switch source {
        case .codex, .claude, .grok:
            output = [
                "hookSpecificOutput": [
                    "hookEventName": event.name.rawValue,
                    "additionalContext": context,
                ],
            ]
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    public static func successOutput(source: HostSource, event: HookEvent) throws -> Data {
        switch (source, event.name) {
        case (.codex, _), (.claude, _), (.grok, _):
            return Data("{}".utf8)
        }
    }

    private static func string(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                return value
            }
        }
        return nil
    }
}
