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
    /// Reflective companion by default: attitude + silence + optional lane/emotion.
    public static func context(for event: HookEvent, source: HostSource) -> String {
        let assignment = assignment(for: event.agentType)
        let tool = toolReference(source: source)
        let priority = recommendedPriority(for: event.name)

        switch event.name {
        case .userPromptSubmit:
            return """
            Chorus: speak only if this turn needs user-facing reflection. Prefer \(tool) once as lane=companion \
            (voice F1, emotion neutral|warm|focused|concerned|relieved|tired). Text = observe + meaning + one next step — \
            no file lists. Silence is correct when nothing new matters. No HTML/JSON speech in the body.
            """

        case .subagentStart:
            return """
            Subagent: if you speak, use \(tool) with priority=subagent, lane=work, voice \(assignment.voice) (\(assignment.name)). \
            Facts only, one short line; companion lane discouraged. focus/quiet/night may suppress subagent. Silence OK. \
            No HTML/JSON speech in the body.
            """

        case .sessionStart, .stop, .subagentStop:
            return """
            Chorus reflective companion TTS via \(tool). Prefer one short companion line when speech helps; silence when it does not \
            (read-only thrash, same status as last turn, or pure lists already on screen). \
            Companion structure: observe + meaning + one next step or rest. Prefer voice F1, speed ~0.93, volume ~0.85, \
            lane=companion (default), emotion from neutral|warm|focused|concerned|relieved|tired (restrained). \
            Optional work lane for pure facts with role voice \(assignment.voice) (\(assignment.name)), speed ~\(format(assignment.baselineSpeed)). \
            Required args: text, voice, speed, volume. Optional: priority (\(priority.rawValue) default here), lane, emotion. \
            Never inventory files or checklist completions. No HTML/JSON speech in the body. Mute/mode/companion toggle: menu bar only.
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
            // Grok qualifies tools as server__tool; discover via search_tool / use_tool.
            return "MCP tool `chorus__speak` (search_tool / use_tool; server `chorus`)"
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
