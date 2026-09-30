// MCP speak 도구 인자 파싱·검증·제출 단위 테스트
import Foundation
import Testing
@testable import DebriefCore

@Suite("McpSpeakToolTests")
struct McpSpeakToolTests {
    @Test func parseRequiresAllFields() throws {
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments(["text": "hi"])
        }
        let args = try McpSpeakTool.parseArguments([
            "text": "빌드를 완료했습니다.",
            "voice": "F1",
            "speed": 0.93,
            "volume": 0.85,
        ])
        #expect(args.text == "빌드를 완료했습니다.")
        #expect(args.voice == "F1")
        #expect(args.speed == 0.93)
        #expect(args.volume == 0.85)
    }

    @Test func parseRejectsBooleanSpeedAndVolume() {
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments([
                "text": "hi",
                "voice": "F1",
                "speed": true,
                "volume": 0.85,
            ])
        }
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments([
                "text": "hi",
                "voice": "F1",
                "speed": 0.93,
                "volume": false,
            ])
        }
        // JSONSerialization bridges true/false to CFBoolean NSNumbers.
        let json = Data(#"{"text":"hi","voice":"F1","speed":true,"volume":1}"#.utf8)
        let object = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments(object)
        }
    }

    @Test func companionPlaybackUsesTheSessionVoice() async throws {
        let diagnostics = Diagnostics(home: URL(fileURLWithPath: "/tmp/debrief-speak-unused"))
        let sink = RecordingSink()
        let arguments = McpSpeakArguments(text: "안녕", voice: "F1", speed: 0.93, volume: 0.85)
        let result = await McpSpeakTool.execute(
            arguments: arguments,
            sink: sink,
            diagnostics: diagnostics,
            companionVoice: "M4"
        )
        #expect(result.isError == false)
        #expect(await sink.recorded().last?.envelope.voice == "M4")
    }

    @Test func workLaneKeepsTheRequestedVoice() async throws {
        let diagnostics = Diagnostics(home: URL(fileURLWithPath: "/tmp/debrief-speak-unused"))
        let sink = RecordingSink()
        let arguments = McpSpeakArguments(
            text: "사실",
            voice: "M1",
            speed: 1.0,
            volume: 0.8,
            lane: .work
        )
        let result = await McpSpeakTool.execute(
            arguments: arguments,
            sink: sink,
            diagnostics: diagnostics,
            companionVoice: "M4"
        )
        #expect(result.isError == false)
        #expect(await sink.recorded().last?.envelope.voice == "M1")
    }

    @Test func parseReadsSession() throws {
        let parsed = try McpSpeakTool.parseArguments([
            "text": "안녕",
            "voice": "F1",
            "speed": 0.93,
            "volume": 0.85,
            "session": " alpha ",
        ])
        #expect(parsed.session == "alpha")
    }

    @Test func executeSubmitsValidRequest() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "debrief-mcp-speak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = RecordingSink()
        let args = McpSpeakArguments(text: "완료했습니다.", voice: "F1", speed: 0.93, volume: 0.85)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: sink,
            diagnostics: Diagnostics(home: home)
        )
        #expect(!result.isError)
        #expect(await sink.recorded().count == 1)
        #expect(await sink.recorded().first?.envelope.text == "완료했습니다.")
        #expect(await sink.recorded().first?.priority == .main)
    }

    @Test func parseOptionalPriorityDefaultsToMain() throws {
        let main = try McpSpeakTool.parseArguments([
            "text": "hi",
            "voice": "F1",
            "speed": 1.0,
            "volume": 0.5,
        ])
        #expect(main.priority == .main)
        #expect(main.lane == .companion)
        #expect(main.emotion == .neutral)

        let sub = try McpSpeakTool.parseArguments([
            "text": "hi",
            "voice": "F1",
            "speed": 1.0,
            "volume": 0.5,
            "priority": "subagent",
            "lane": "work",
            "emotion": "focused",
        ])
        #expect(sub.priority == .subagent)
        #expect(sub.lane == .work)
        #expect(sub.emotion == .focused)

        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments([
                "text": "hi",
                "voice": "F1",
                "speed": 1.0,
                "volume": 0.5,
                "priority": "boss",
            ])
        }
        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments([
                "text": "hi",
                "voice": "F1",
                "speed": 1.0,
                "volume": 0.5,
                "emotion": "angry",
            ])
        }
    }

    @Test func executeAppliesEmotionProsodyToEnvelope() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "debrief-mcp-emotion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = RecordingSink()
        let args = McpSpeakArguments(
            text: "잠시 쉬어도 됩니다.",
            voice: "F1",
            speed: 1.0,
            volume: 1.0,
            emotion: .tired
        )
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: sink,
            diagnostics: Diagnostics(home: home)
        )
        #expect(!result.isError)
        let env = await sink.recorded().first?.envelope
        #expect(env?.speed == 0.92)
        #expect(env?.volume == 0.90)
        #expect(await sink.recorded().first?.lane == .companion)
        #expect(await sink.recorded().first?.emotion == .tired)
    }

    @Test func executeRejectsBadVoiceWithoutSubmit() async {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "debrief-mcp-speak-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = RecordingSink()
        let args = McpSpeakArguments(text: "x", voice: "BAD", speed: 1, volume: 1)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: sink,
            diagnostics: Diagnostics(home: home)
        )
        #expect(result.isError)
        #expect(await sink.recorded().isEmpty)
    }

    @Test func sinkFailureIsErrorAndRecordsDiagnostics() async {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "debrief-mcp-speak-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let diagnostics = Diagnostics(home: home)
        let args = McpSpeakArguments(text: "x", voice: "F1", speed: 1, volume: 0.5)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: RecordingSink(shouldFail: true),
            diagnostics: diagnostics
        )
        #expect(result.isError)
        // RecordingSink throws RecordingSinkError.rejected → shortError uses String(describing:).
        #expect(!result.message.isEmpty)
        #expect(result.message.localizedCaseInsensitiveContains("rejected"))
        let error = diagnostics.currentError()
        #expect(error?.component == "mcp")
        #expect(error?.code == "delivery_failed")
        #expect(error?.message.contains("mcp speak:") == true)
    }
}
