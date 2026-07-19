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
        #expect(await sink.recorded().first?.event == .stop)
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

        let args = McpSpeakArguments(text: "x", voice: "F1", speed: 1, volume: 0.5)
        let result = await McpSpeakTool.execute(
            arguments: args,
            sink: RecordingSink(shouldFail: true),
            diagnostics: Diagnostics(home: home)
        )
        #expect(result.isError)
        #expect(result.message.contains("연결") || result.message.localizedCaseInsensitiveContains("fail")
            || !result.message.isEmpty)
        let errURL = ChorusPaths.forHome(home).lastErrorURL
        #expect(FileManager.default.fileExists(atPath: errURL.path))
    }
}
