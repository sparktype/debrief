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
                "plan", "feature-dev", "gan-planner",
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
                "claude-code-guide",
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

    public static func context(for agentType: String?) -> String {
        let assignment = assignment(for: agentType)
        return """
        When you finish this turn, call the Chorus MCP tool `speak` once with a one- or two-sentence spoken summary. \
        Required arguments: text, voice, speed, volume. \
        Optional: priority \"main\" (default) or \"subagent\" — use subagent for background agents so focus/quiet/night can suppress them. \
        Use voice \(assignment.voice) (\(assignment.name)); choose speed from 0.7 through 2.0 (baseline \(assignment.baselineSpeed)) \
        and volume from 0.0 through 1.0 (typical 0.85). \
        Keep text at 800 characters or fewer. \
        Do not put HTML comments, JSON speech metadata, or legacy speech envelope markers in the assistant message body.
        """
    }
}
