import Foundation
import Testing
@testable import DebriefCore

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
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text.contains("M1"))
        #expect(text.contains("subagent"))
        #expect(text.contains("mcp__debrief__speak") || text.contains("speak"))
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

    @Test func sessionVoicesRotateAndSubagentsDoNotTakeASlot() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "debrief-hook-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SessionVoiceStore(url: url)
        let engine = HookEngine(sink: RecordingSink(), sessionVoices: store)

        func text(_ result: HookResult) -> String {
            String(decoding: result.stdout, as: UTF8.self)
        }
        let first = await engine.handle(
            HookEvent(name: .sessionStart, sessionID: "alpha", turnID: nil, agentType: nil, lastAssistantMessage: nil),
            source: .claude
        )
        let second = await engine.handle(
            HookEvent(name: .sessionStart, sessionID: "beta", turnID: nil, agentType: nil, lastAssistantMessage: nil),
            source: .claude
        )
        let again = await engine.handle(
            HookEvent(name: .userPromptSubmit, sessionID: "alpha", turnID: "t", agentType: nil, lastAssistantMessage: nil),
            source: .claude
        )
        let subagent = await engine.handle(
            HookEvent(name: .subagentStart, sessionID: "child", turnID: nil, agentType: "planner", lastAssistantMessage: nil),
            source: .claude
        )

        #expect(text(first).contains("F1 (연아)"))
        #expect(text(second).contains("F2 (마리)"))
        #expect(text(again).contains("F1 (연아)"))
        #expect(text(subagent).contains("M1"))
        #expect(!text(subagent).contains("session="))
        #expect(try store.claim("gamma") == "F3")
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

    @Test func stopDoesNotSubmitEvenWithLegacyEnvelope() async {
        let sink = RecordingSink()
        let event = HookEvent(
            name: .stop,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage:
                "<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"F1\",\"speed\":0.93,\"volume\":0.85} -->"
        )
        let result = await HookEngine(sink: sink).handle(event, source: .claude)
        #expect(!result.submitted)
        #expect(await sink.recorded().isEmpty)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        #expect(result.deliveryError == nil)
    }

    @Test func subagentStopDoesNotSubmitEvenWithLegacyEnvelope() async {
        let sink = RecordingSink()
        let event = HookEvent(
            name: .subagentStop,
            sessionID: "s",
            turnID: "t",
            agentType: "planner",
            lastAssistantMessage:
                "<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"M1\",\"speed\":1.1,\"volume\":0.85} -->"
        )
        let result = await HookEngine(sink: sink).handle(event, source: .claude)
        #expect(!result.submitted)
        #expect(await sink.recorded().isEmpty)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        #expect(result.deliveryError == nil)
    }

    @Test func stopWithoutMessageIsSuccessfulNoOp() async {
        let sink = RecordingSink()
        let event = HookEvent(
            name: .stop,
            sessionID: "s",
            turnID: nil,
            agentType: nil,
            lastAssistantMessage: "visible only"
        )
        let result = await HookEngine(sink: sink).handle(event, source: .claude)
        #expect(!result.submitted)
        #expect(result.deliveryError == nil)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{}")
        #expect(await sink.recorded().isEmpty)
    }
}
