// MCP speak 도구 인자 파싱·검증·제출 단위 테스트
import Foundation
import Testing
@testable import ChorusCore

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

    @Test func executeSubmitsValidRequest() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
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

        let sub = try McpSpeakTool.parseArguments([
            "text": "hi",
            "voice": "F1",
            "speed": 1.0,
            "volume": 0.5,
            "priority": "subagent",
        ])
        #expect(sub.priority == .subagent)

        #expect(throws: (any Error).self) {
            try McpSpeakTool.parseArguments([
                "text": "hi",
                "voice": "F1",
                "speed": 1.0,
                "volume": 0.5,
                "priority": "boss",
            ])
        }
    }

    @Test func executeRejectsBadVoiceWithoutSubmit() async {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
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
            .appending(path: "chorus-mcp-speak-\(UUID().uuidString)")
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
