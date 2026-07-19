import Testing
@testable import ChorusCore

@Suite("VoiceCatalogTests")
struct VoiceCatalogTests {
    @Test(arguments: [
        ("code-reviewer", "M3"),
        ("planner", "M1"),
        ("feature-builder", "M4"),
        ("e2e-runner", "F2"),
        ("explore", "F3"),
        ("code-simplifier", "M3"),
        ("security-reviewer", "M3"),
        ("dependency-expert", "F5"),
        ("unknown-agent", "F1"),
    ])
    func preservesVoiceRouting(agentType: String, voice: String) {
        #expect(VoiceCatalog.assignment(for: agentType).voice == voice)
    }

    @Test func preservesEveryLegacyCategoryEntry() {
        let expected: [String: [String]] = [
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

        #expect(expected.values.reduce(0) { $0 + $1.count } == 67)
        for (category, agentTypes) in expected {
            for agentType in agentTypes {
                #expect(VoiceCatalog.assignment(for: agentType).category == category)
            }
        }
    }

    @Test func contextMentionsSpeakToolNotHtmlEnvelope() {
        let text = VoiceCatalog.context(for: "planner")
        #expect(text.contains("speak"))
        #expect(text.contains("M1"))
        #expect(text.contains("스티브"))
        #expect(text.contains("0.7"))
        #expect(text.contains("2.0"))
        #expect(text.contains("800"))
        #expect(!text.contains("chorus:speak"))
        #expect(!text.contains("<!--"))
        #expect(!text.localizedCaseInsensitiveContains("Chorus summarizes"))
    }
}

