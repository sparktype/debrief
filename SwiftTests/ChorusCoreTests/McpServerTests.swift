// MCP JSON-RPC 핸들러 단위 테스트
import Foundation
import Testing
@testable import ChorusCore

@Suite("McpServerTests")
struct McpServerTests {
    @Test func initializeReturnsServerInfo() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "t", "version": "0"]],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in McpToolCallResult(isError: true, message: "no") })
        let result = res?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String != nil)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "chorus")
    }

    @Test func toolsListContainsSpeak() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in .init(isError: false, message: "") })!
        let tools = (res["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains(where: { ($0["name"] as? String) == "speak" }) == true)
    }

    @Test func toolsCallSpeakInvokesHandler() async {
        let box = SeenBox()
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "speak",
                "arguments": [
                    "text": "hi", "voice": "F1", "speed": 1.0, "volume": 0.5,
                ],
            ],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { args in
            box.text = args["text"] as? String
            return McpToolCallResult(isError: false, message: #"{"ok":true}"#)
        })!
        #expect(box.text == "hi")
        let result = res["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
    }

    @Test func notificationsReturnNilResponse() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in .init(isError: false, message: "") })
        #expect(res == nil)
    }
}

/// Captures speak text without non-Sendable dictionary transfer.
private final class SeenBox: @unchecked Sendable {
    var text: String?
}
