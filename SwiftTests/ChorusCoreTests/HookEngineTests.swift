import Foundation
import Testing
@testable import ChorusCore

@Suite("HookEngineTests")
struct HookEngineTests {
    @Test func subagentContextUsesAssignedVoice() async {
        let event = HookEvent(
            name: .subagentStart,
            sessionID: "s",
            turnID: "t",
            agentType: "planner",
            lastAssistantMessage: nil
        )
        let result = await HookEngine(sink: RecordingSink()).handle(event, source: .claude)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("M1"))
        #expect(!result.submitted)
    }

    @Test func validStopSubmitsExactlyOnce() async throws {
        let sink = RecordingSink()
        let event = try HookAdapter.decode(Fixture.load("codex-stop.json"), source: .codex)
        let result = await HookEngine(sink: sink).handle(event, source: .codex)

        #expect(result.submitted)
        #expect(await sink.recorded().count == 1)
        #expect(await sink.recorded().first?.envelope.text == "Codex 작업을 완료했습니다.")
    }

    @Test func invalidOrMismatchedEnvelopeIsSuccessfulNoOp() async {
        let sink = RecordingSink()
        let messages = [
            "visible only",
            "<!-- chorus:speak {\"v\":1,\"text\":\"wrong\",\"voice\":\"M4\",\"speed\":1,\"volume\":0.8} -->",
        ]

        for message in messages {
            let event = HookEvent(
                name: .stop,
                sessionID: "s",
                turnID: nil,
                agentType: nil,
                lastAssistantMessage: message
            )
            let result = await HookEngine(sink: sink).handle(event, source: .claude)
            #expect(!result.submitted)
            #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        }
        #expect(await sink.recorded().isEmpty)
    }

    @Test func sinkFailureDoesNotAffectAgentCompletion() async throws {
        let event = try HookAdapter.decode(Fixture.load("claude-stop.json"), source: .claude)
        let result = await HookEngine(sink: RecordingSink(shouldFail: true)).handle(event, source: .claude)

        #expect(!result.submitted)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        #expect(!String(decoding: result.stdout, as: UTF8.self).contains("continue"))
    }
}
