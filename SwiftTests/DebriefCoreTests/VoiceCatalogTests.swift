import Testing
@testable import DebriefCore

@Suite("VoiceCatalogTests")
struct VoiceCatalogTests {
    @Test(arguments: [
        ("code-reviewer", "M2"),
        ("planner", "M1"),
        ("feature-builder", "M4"),
        ("e2e-runner", "F2"),
        ("explore", "F3"),
        ("code-simplifier", "M2"),
        ("security-reviewer", "M2"),
        ("performance-optimizer", "M3"),
        ("dependency-expert", "F5"),
        ("unknown-agent", "F1"),
        ("Plan", "M1"),
        ("Task", "F3"),
    ])
    func preservesVoiceRouting(agentType: String, voice: String) {
        #expect(VoiceCatalog.assignment(for: agentType).voice == voice)
    }

    @Test func rolesUseDistinctVoices() {
        let roles = [
            "reviewer", "planner", "builder", "tester", "explorer",
            "optimizer", "guardian", "ops", "specialist", "default",
        ]
        let assignments = roles.map { VoiceCatalog.assignment(for: $0) }
        #expect(Set(assignments.map(\.voice)).count == roles.count)
        #expect(Set(assignments.map(\.name)).count == roles.count)
        let reviewer = VoiceCatalog.assignment(for: "reviewer")
        #expect(reviewer.voice == "M2")
        #expect(reviewer.name == "빌")
        #expect(reviewer.baselineSpeed == 0.92)
        #expect(VoiceCatalog.assignment(for: "optimizer").voice == "M3")
        #expect(VoiceCatalog.assignment(for: "optimizer").name == "일론")
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

        #expect(expected.values.reduce(0) { $0 + $1.count } == 69)
        for (category, agentTypes) in expected {
            for agentType in agentTypes {
                #expect(VoiceCatalog.assignment(for: agentType).category == category)
            }
        }
    }

    @Test func contextMentionsSpeakToolNotHtmlEnvelope() {
        let text = VoiceCatalog.context(for: "planner")
        #expect(text.contains("speak") || text.contains("mcp__debrief__speak"))
        #expect(text.contains("companion") || text.contains("F1"))
        #expect(text.contains("emotion") || text.contains("neutral"))
        #expect(!text.contains("chorus:speak"))
        #expect(!text.contains("<!--"))
        #expect(!text.localizedCaseInsensitiveContains("Debrief summarizes"))
    }

    @Test func claudeContextNamesMcpToolAlias() {
        let event = HookEvent(
            name: .sessionStart,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: nil
        )
        let text = VoiceCatalog.context(for: event, source: .claude)
        #expect(text.contains("mcp__debrief__speak"))
        #expect(text.contains("F1"))
        #expect(text.localizedCaseInsensitiveContains("silence") || text.contains("침묵") || text.contains("does not"))
    }

    @Test func subagentContextRequestsSubagentPriority() {
        let event = HookEvent(
            name: .subagentStart,
            sessionID: "s",
            turnID: "t",
            agentType: "planner",
            lastAssistantMessage: nil
        )
        let text = VoiceCatalog.context(for: event, source: .claude)
        #expect(text.contains("subagent"))
        #expect(text.contains("M1"))
        #expect(text.contains("work") || text.contains("priority"))
        #expect(text.contains("do not brief"))
    }

    @Test func userPromptSubmitContextIsCompact() {
        let event = HookEvent(
            name: .userPromptSubmit,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: nil
        )
        let text = VoiceCatalog.context(for: event, source: .claude)
        #expect(text.count < 400)
        #expect(text.contains("companion") || text.contains("F1"))
        #expect(text.contains("Silence only"))
        #expect(text.contains("what changed"))
        #expect(text.contains("next action"))
        #expect(text.contains("ownership"))
    }

    @Test func sessionStartBriefsWhatChangedThenNextAction() {
        let event = HookEvent(
            name: .sessionStart,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: nil
        )
        let text = VoiceCatalog.context(for: event, source: .claude)
        #expect(text.contains("what changed"))
        #expect(text.contains("next action"))
        #expect(text.contains("agent writes"))
        #expect(text.contains("Silence only"))
        #expect(text.contains("debrief mute"))
        #expect(text.contains("ownership"))
        #expect(!text.localizedCaseInsensitiveContains("menu bar"))
        #expect(!text.contains("menubar"))
        #expect(!text.localizedCaseInsensitiveContains("Debrief summarizes"))
    }
}
