import Foundation
import Testing
@testable import ChorusCore

@Suite("HookAdapterTests")
struct HookAdapterTests {
    @Test(arguments: [HostSource.codex, .claude])
    func stopNormalizesEnvelopeText(source: HostSource) throws {
        let data = try Fixture.load("\(source.rawValue)-stop.json")
        let event = try HookAdapter.decode(data, source: source)

        #expect(event.name == .stop)
        #expect(event.lastAssistantMessage?.contains("chorus:speak") == true)
    }

    @Test(arguments: [
        (HostSource.codex, "codex-session-start.json", HookEventName.sessionStart),
        (.codex, "codex-user-prompt-submit.json", .userPromptSubmit),
        (.codex, "codex-subagent-start.json", .subagentStart),
        (.codex, "codex-stop.json", .stop),
        (.codex, "codex-subagent-stop.json", .subagentStop),
        (.claude, "claude-session-start.json", .sessionStart),
        (.claude, "claude-user-prompt-submit.json", .userPromptSubmit),
        (.claude, "claude-subagent-start.json", .subagentStart),
        (.claude, "claude-stop.json", .stop),
        (.claude, "claude-subagent-stop.json", .subagentStop),
    ])
    func normalizesAllFixtures(source: HostSource, fixture: String, expected: HookEventName) throws {
        let event = try HookAdapter.decode(Fixture.load(fixture), source: source)
        #expect(event.name == expected)
        #expect(!event.sessionID.isEmpty)
        if expected == .subagentStart || expected == .subagentStop {
            #expect(event.agentType == "planner")
        }
    }

    @Test(arguments: [HostSource.codex, .claude])
    func contextOutputUsesHookSpecificAdditionalContext(source: HostSource) throws {
        let event = HookEvent(
            name: .sessionStart,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: nil
        )
        let data = try HookAdapter.contextOutput("context", source: source, event: event)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("hookSpecificOutput"))
        #expect(text.contains("additionalContext"))
        #expect(text.contains("SessionStart"))
    }

    @Test func codexLiveStopPreservesCompleteEnvelopeComment() throws {
        let event = try HookAdapter.decode(Fixture.load("codex-stop-live.json"), source: .codex)
        #expect(event.lastAssistantMessage == """
        완료.
        <!-- chorus:speak {"v":1,"text":"Codex 보존 검증을 완료했습니다.","voice":"F1","speed":0.93,"volume":0.6} -->
        """)
    }
}
