// MCP JSON-RPC 핸들러 단위 테스트
import Darwin
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

    @Test func toolsListContainsSpeakAndInstall() async {
        let req: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ]
        let res = await McpJSONRPC.handle(request: req, speak: { _ in .init(isError: false, message: "") })!
        let tools = (res["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains(where: { ($0["name"] as? String) == "speak" }) == true)
        #expect(tools?.contains(where: { ($0["name"] as? String) == "install" }) == true)
    }

    @Test func toolsCallInstallInvokesHandler() async {
        let box = SeenBox()
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": "install",
                "arguments": ["hosts": ["claude"], "repair": true],
            ],
        ]
        let res = await McpJSONRPC.handle(request: req, callTool: { name, args in
            box.text = name
            #expect((args["hosts"] as? [String]) == ["claude"])
            return McpToolCallResult(isError: false, message: #"{"ok":true}"#)
        })!
        #expect(box.text == "install")
        let result = res["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
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

    @Test func parseErrorResponseUsesCode32700AndNullId() {
        let res = McpJSONRPC.parseErrorResponse()
        #expect(res["jsonrpc"] as? String == "2.0")
        #expect(res["id"] is NSNull)
        let error = res["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700)
        #expect(error?["message"] as? String == "Parse error")
    }

    @Test func contentLengthRejectsNegativeAndAbsurdLarge() {
        #expect(McpFraming.validatedContentLength(0) == 0)
        #expect(McpFraming.validatedContentLength(42) == 42)
        #expect(McpFraming.validatedContentLength(McpFraming.maxContentLength) == McpFraming.maxContentLength)
        #expect(McpFraming.validatedContentLength(-1) == nil)
        #expect(McpFraming.validatedContentLength(McpFraming.maxContentLength + 1) == nil)
    }

    /// Host MCP clients keep the stdin write end open after the first frame.
    /// FileHandle.read(upToCount:) may wait for a full buffer or EOF on pipes;
    /// the server must answer initialize without requiring EOF.
    @Test func initializeRespondsWhileStdinWriteEndStaysOpen() async throws {
        let response = try await roundTripInitialize(
            request: contentLengthFrame(initializeBody(id: 1)),
            expectNewlineDelimited: false
        )
        #expect(response["id"] as? Int == 1)
        let result = response["result"] as? [String: Any]
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "chorus")
    }

    /// Grok (and some other hosts) speak newline-delimited JSON-RPC on stdio,
    /// not Content-Length framing. The server must answer in the same format.
    @Test func initializeRespondsToNewlineDelimitedJSON() async throws {
        let body = initializeBody(id: 0)
        var line = body
        line.append(0x0A)
        let response = try await roundTripInitialize(
            request: line,
            expectNewlineDelimited: true
        )
        #expect(response["id"] as? Int == 0)
        let result = response["result"] as? [String: Any]
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "chorus")
    }
}

/// Captures speak text without non-Sendable dictionary transfer.
private final class SeenBox: @unchecked Sendable {
    var text: String?
}

private struct NoopSpeechSink: SpeechSink {
    func submit(_ request: SpeechRequest) async throws {}
}

private func initializeBody(id: Int) -> Data {
    Data(
        """
        {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
        """.utf8
    )
}

private func contentLengthFrame(_ body: Data) -> Data {
    var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    frame.append(body)
    return frame
}

private func roundTripInitialize(
    request: Data,
    expectNewlineDelimited: Bool
) async throws -> [String: Any] {
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let home = FileManager.default.temporaryDirectory
        .appending(path: "chorus-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let server = McpServer(
        home: home,
        sink: NoopSpeechSink(),
        input: inputPipe.fileHandleForReading,
        output: outputPipe.fileHandleForWriting
    )
    let runTask = Task { await server.run() }

    try inputPipe.fileHandleForWriting.write(contentsOf: request)
    // Intentionally leave the write end open (real host behavior).

    let response = try await readResponseJSON(
        from: outputPipe.fileHandleForReading,
        expectNewlineDelimited: expectNewlineDelimited,
        timeoutSeconds: 3
    )

    try inputPipe.fileHandleForWriting.close()
    await runTask.value
    return response
}

private func readResponseJSON(
    from handle: FileHandle,
    expectNewlineDelimited: Bool,
    timeoutSeconds: TimeInterval
) async throws -> [String: Any] {
    let fd = handle.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var buffer = Data()
    while Date() < deadline {
        if expectNewlineDelimited {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                let object = try JSONSerialization.jsonObject(with: line)
                guard let dict = object as? [String: Any] else {
                    throw NSError(domain: "McpServerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "response not object"])
                }
                // Response must be NDJSON (no Content-Length header prefix).
                #expect(!buffer.starts(with: Data("Content-Length:".utf8)))
                return dict
            }
        } else if let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let header = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
            var length: Int?
            for line in header.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("content-length:") {
                    let value = trimmed.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                    length = Int(value)
                }
            }
            guard let length else {
                throw NSError(domain: "McpServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing content-length"])
            }
            let bodyStart = headerEnd.upperBound
            if buffer.count >= bodyStart + length {
                let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
                let object = try JSONSerialization.jsonObject(with: body)
                guard let dict = object as? [String: Any] else {
                    throw NSError(domain: "McpServerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "response not object"])
                }
                return dict
            }
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n > 0 {
            buffer.append(contentsOf: bytes.prefix(n))
            continue
        }
        if n == 0 {
            break // EOF before a full frame
        }
        // EAGAIN / EWOULDBLOCK — wait and retry
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw NSError(
        domain: "McpServerTests",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for MCP frame (\(buffer.count) bytes buffered)"]
    )
}
