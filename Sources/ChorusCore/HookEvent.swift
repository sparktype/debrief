import Foundation

public enum HostSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum HookEventName: String, Codable, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case subagentStart = "SubagentStart"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
}

public struct HookEvent: Codable, Equatable, Sendable {
    public let name: HookEventName
    public let sessionID: String
    public let turnID: String?
    public let agentType: String?
    public let lastAssistantMessage: String?

    public init(
        name: HookEventName,
        sessionID: String,
        turnID: String?,
        agentType: String?,
        lastAssistantMessage: String?
    ) {
        self.name = name
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentType = agentType
        self.lastAssistantMessage = lastAssistantMessage
    }
}
