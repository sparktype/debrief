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
        #expect(result.deliveryError == nil)
    }

    @Test func sessionStartUsesHostAgentTypeWhenPresent() async {
        let event = HookEvent(
            name: .sessionStart,
            sessionID: "s",
            turnID: nil,
            agentType: "Explore",
            lastAssistantMessage: nil
        )
        let result = await HookEngine(sink: RecordingSink()).handle(event, source: .claude)
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text.contains("F3"))
        #expect(text.contains("제인"))
        #expect(!result.submitted)
    }

    @Test func userPromptSubmitDefaultsToMainVoiceWithoutAgentType() async {
        let event = HookEvent(
            name: .userPromptSubmit,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: nil
        )
        let result = await HookEngine(sink: RecordingSink()).handle(event, source: .claude)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("F1"))
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
        let missing = HookEvent(
            name: .stop,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: "visible only"
        )
        let missingResult = await HookEngine(sink: sink).handle(missing, source: .claude)
        #expect(!missingResult.submitted)
        #expect(missingResult.deliveryError == nil)
        #expect(String(decoding: missingResult.stdout, as: UTF8.self) == "{}")

        let mismatched = HookEvent(
            name: .stop,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage:
                "<!-- chorus:speak {\"v\":1,\"text\":\"wrong\",\"voice\":\"M4\",\"speed\":1,\"volume\":0.8} -->"
        )
        let mismatchResult = await HookEngine(sink: sink).handle(mismatched, source: .claude)
        #expect(!mismatchResult.submitted)
        #expect(mismatchResult.deliveryError?.contains("보이스 불일치") == true)
        #expect(String(decoding: mismatchResult.stdout, as: UTF8.self) == "{}")
        #expect(await sink.recorded().isEmpty)
    }

    @Test func sinkFailureDoesNotAffectAgentCompletion() async throws {
        let event = try HookAdapter.decode(Fixture.load("claude-stop.json"), source: .claude)
        let result = await HookEngine(sink: RecordingSink(shouldFail: true)).handle(event, source: .claude)

        #expect(!result.submitted)
        #expect(result.deliveryError?.contains("TTS 전송 실패") == true)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        #expect(!String(decoding: result.stdout, as: UTF8.self).contains("continue"))
    }
}
