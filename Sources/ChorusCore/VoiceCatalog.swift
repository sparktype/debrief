import Foundation

public struct VoiceAssignment: Equatable, Sendable {
    public let category: String
    public let voice: String
    public let name: String
    public let baselineSpeed: Double

    public init(category: String, voice: String, name: String, baselineSpeed: Double) {
        self.category = category
        self.voice = voice
        self.name = name
        self.baselineSpeed = baselineSpeed
    }
}

public enum VoiceCatalog {
    public static let allowedVoiceIDs: Set<String> = [
        "F1", "F2", "F3", "F4", "F5",
        "M1", "M2", "M3", "M4", "M5",
    ]

    private static let assignments: [String: VoiceAssignment] = [
        "reviewer": .init(category: "reviewer", voice: "M3", name: "일론", baselineSpeed: 1.00),
        "planner": .init(category: "planner", voice: "M1", name: "스티브", baselineSpeed: 1.10),
        "builder": .init(category: "builder", voice: "M4", name: "리누스", baselineSpeed: 0.95),
        "tester": .init(category: "tester", voice: "F2", name: "마리", baselineSpeed: 1.10),
        "explorer": .init(category: "explorer", voice: "F3", name: "제인", baselineSpeed: 1.00),
        "optimizer": .init(category: "optimizer", voice: "M3", name: "일론", baselineSpeed: 1.00),
        "guardian": .init(category: "guardian", voice: "M5", name: "팀", baselineSpeed: 0.88),
        "ops": .init(category: "ops", voice: "F4", name: "셰릴", baselineSpeed: 1.05),
        "specialist": .init(category: "specialist", voice: "F5", name: "리사", baselineSpeed: 0.88),
        "default": .init(category: "default", voice: "F1", name: "연아", baselineSpeed: 0.93),
    ]

    private static let agentCategories: [String: String] = {
        let legacy: [String: [String]] = [
            "reviewer": [
                "feature-reviewer", "code-reviewer", "python-reviewer", "security-reviewer",
                "typescript-reviewer", "rust-reviewer", "go-reviewer", "kotlin-reviewer",
                "swift-reviewer", "cpp-reviewer", "java-reviewer", "csharp-reviewer",
                "flutter-reviewer", "fastapi-reviewer", "database-reviewer", "mle-reviewer",
                "pr-test-analyzer", "code-simplifier",
            ],
            "planner": [
                "feature-architect", "planner", "architect", "code-architect", "a11y-architect",
                "plan", "feature-dev", "gan-planner", "Plan",
            ],
            "builder": [
                "feature-builder", "build-error-resolver", "dart-build-resolver",
                "rust-build-resolver", "go-build-resolver", "kotlin-build-resolver",
                "swift-build-resolver", "cpp-build-resolver", "java-build-resolver",
                "pytorch-build-resolver", "gan-generator", "multi-execute", "doc-updater",
                "refactor-cleaner",
            ],
            "tester": ["feature-tester", "tdd-guide", "e2e-runner", "gan-evaluator"],
            "explorer": [
                "Explore", "code-explorer", "general-purpose", "gitnexus-exploring",
                "claude-code-guide", "Task",
            ],
            "optimizer": ["performance-optimizer", "harness-optimizer", "type-design-analyzer"],
            "guardian": ["silent-failure-hunter", "comment-analyzer", "conversation-analyzer"],
            "ops": [
                "loop-operator", "network-troubleshooter", "network-config-reviewer",
                "opensource-forker", "opensource-packager", "opensource-sanitizer", "hookify",
                "statusline-setup",
            ],
            "specialist": ["healthcare-reviewer", "seo-specialist", "chief-of-staff", "claude"],
        ]
        let aliases: [String: [String]] = [
            "reviewer": ["verifier", "critic"],
            "builder": ["executor"],
            "tester": ["test-engineer"],
            "explorer": ["explore", "researcher"],
            "guardian": ["debugger"],
            "specialist": ["dependency-expert"],
        ]

        var result: [String: String] = [:]
        for category in assignments.keys where category != "default" {
            result[category] = category
        }
        for source in [legacy, aliases] {
            for (category, agentTypes) in source {
                for agentType in agentTypes {
                    result[agentType] = category
                }
            }
        }
        return result
    }()

    public static func assignment(for agentType: String?) -> VoiceAssignment {
        guard let agentType else { return assignments["default"]! }
        let category = agentCategories[agentType]
            ?? agentCategories[agentType.lowercased()]
            ?? "default"
        return assignments[category] ?? assignments["default"]!
    }

    /// MCP speak contract for start-family hooks (host- and event-aware).
    public static func context(for event: HookEvent, source: HostSource) -> String {
        let assignment = assignment(for: event.agentType)
        let tool = toolReference(source: source)
        let priority = recommendedPriority(for: event.name)
        let volumeHint = "0.85"

        switch event.name {
        case .userPromptSubmit:
            // Compact: UserPromptSubmit fires every turn — keep token cost low.
            return """
            Chorus TTS: at end of this turn call \(tool) once with text (≤800 chars), \
            voice \(assignment.voice), speed near \(format(assignment.baselineSpeed)), volume near \(volumeHint). \
            priority=\(priority.rawValue). No HTML comments or speech JSON in the message body.
            """

        case .subagentStart:
            return """
            You are a subagent. When you finish this turn, call \(tool) once with a one- or two-sentence spoken summary. \
            Required: text, voice, speed, volume. Set priority to \"subagent\" so focus/quiet/night can suppress you. \
            Use voice \(assignment.voice) (\(assignment.name)); speed baseline \(format(assignment.baselineSpeed)) (range 0.7–2.0); \
            volume near \(volumeHint) (range 0.0–1.0). Keep text ≤ 800 characters. \
            Do not put HTML comments, JSON speech metadata, or legacy speech envelopes in the assistant message body. \
            Omitting the tool is silence — the user will not hear a summary.
            """

        case .sessionStart, .stop, .subagentStop:
            return """
            When you finish a turn that deserves spoken feedback, call \(tool) once with a one- or two-sentence summary. \
            Required arguments: text, voice, speed, volume. Optional priority: \"main\" (default) or \"subagent\". \
            Prefer voice \(assignment.voice) (\(assignment.name)); speed near \(format(assignment.baselineSpeed)) (0.7–2.0); \
            volume near \(volumeHint) (0.0–1.0). Keep text ≤ 800 characters. \
            Call the tool at the end of the turn — do not put HTML comments or JSON speech metadata in the message body. \
            If you skip the tool, the user hears nothing. Mute/mode are menu-bar only (not CLI).
            """
        }
    }

    /// Back-compat helper used by older tests/callers without event metadata.
    public static func context(for agentType: String?) -> String {
        context(
            for: HookEvent(
                name: .sessionStart,
                sessionID: "compat",
                turnID: nil,
                agentType: agentType,
                lastAssistantMessage: nil
            ),
            source: .claude
        )
    }

    private static func toolReference(source: HostSource) -> String {
        switch source {
        case .claude:
            // Claude Code often qualifies MCP tools as mcp__<server>__<tool>.
            return "MCP tool `speak` on server `chorus` (may appear as `mcp__chorus__speak`)"
        case .codex:
            return "MCP tool `speak` on server `chorus`"
        case .grok:
            return "MCP tool `chorus__speak` (server `chorus`)"
        }
    }

    private static func recommendedPriority(for event: HookEventName) -> SpeechPriority {
        switch event {
        case .subagentStart, .subagentStop:
            return .subagent
        case .sessionStart, .userPromptSubmit, .stop:
            return .main
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
