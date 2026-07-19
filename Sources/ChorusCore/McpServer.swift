// MCP stdio JSON-RPC 서버 (speak 도구)
import Foundation

/// Pure JSON-RPC method dispatch for MCP (testable without FileHandle).
public enum McpJSONRPC {
    public static func handle(
        request: [String: Any],
        speak: @escaping @Sendable ([String: Any]) async -> McpToolCallResult
    ) async -> [String: Any]? {
        let method = request["method"] as? String
        let id = request["id"]

        // Notifications (no id) return no response body.
        if id == nil {
            // Still accept known notifications; unknown ones are ignored too.
            return nil
        }

        guard let method else {
            return errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            let params = request["params"] as? [String: Any] ?? [:]
            let protocolVersion = params["protocolVersion"] as? String ?? "2024-11-05"
            return successResponse(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": [
                    "name": "chorus",
                    "version": ChorusVersion.current,
                ] as [String: Any],
            ] as [String: Any])

        case "notifications/initialized":
            // Should normally arrive without id; if it has one, still no body needed.
            return nil

        case "tools/list":
            return successResponse(id: id, result: [
                "tools": [speakToolDefinition()],
            ] as [String: Any])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String
            guard name == "speak" else {
                return errorResponse(
                    id: id,
                    code: -32601,
                    message: "Method not found: tool \(name ?? "(nil)")"
                )
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let toolResult = await speak(arguments)
            return successResponse(id: id, result: [
                "content": [
                    ["type": "text", "text": toolResult.message] as [String: Any],
                ],
                "isError": toolResult.isError,
            ] as [String: Any])

        case "ping":
            return successResponse(id: id, result: [:] as [String: Any])

        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func speakToolDefinition() -> [String: Any] {
        [
            "name": "speak",
            "description":
                "Speak a short one- or two-sentence summary of the finished work through local Chorus TTS. "
                + "Call once at the end of a turn when speech is appropriate. "
                + "Do not put HTML comments or JSON speech metadata in the assistant message body.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"] as [String: Any],
                    "voice": ["type": "string"] as [String: Any],
                    "speed": ["type": "number"] as [String: Any],
                    "volume": ["type": "number"] as [String: Any],
                ] as [String: Any],
                "required": ["text", "voice", "speed", "volume"],
            ] as [String: Any],
        ]
    }

    private static func successResponse(id: Any?, result: Any) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id {
            response["id"] = id
        } else {
            response["id"] = NSNull()
        }
        return response
    }

    /// JSON-RPC parse error (−32700) with `id: null`.
    public static func parseErrorResponse() -> [String: Any] {
        errorResponse(id: nil, code: -32700, message: "Parse error")
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        if let id {
            response["id"] = id
        } else {
            response["id"] = NSNull()
        }
        return response
    }
}

/// Content-Length framing limits (shared with FrameReader).
public enum McpFraming {
    public static let maxContentLength = 1_000_000

    /// Accept non-negative lengths up to `maxContentLength`; reject otherwise.
    public static func validatedContentLength(_ length: Int) -> Int? {
        guard length >= 0, length <= maxContentLength else { return nil }
        return length
    }
}

/// Host-spawned stdio MCP server; validates speak and submits via UDS.
public struct McpServer: Sendable {
    private let home: URL
    private let sink: any SpeechSink
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: Diagnostics

    public init(
        home: URL,
        sink: (any SpeechSink)? = nil,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.home = home
        let paths = ChorusPaths.forHome(home)
        self.sink = sink ?? UnixSocketClient(socketURL: paths.socketURL)
        self.input = input
        self.output = output
        self.diagnostics = Diagnostics(home: home)
    }

    /// Run until stdin EOF. Uses MCP Content-Length framing.
    public func run() async {
        let reader = FrameReader(handle: input)
        let sink = self.sink
        let diagnostics = self.diagnostics
        let speak: @Sendable ([String: Any]) async -> McpToolCallResult = { arguments in
            do {
                let parsed = try McpSpeakTool.parseArguments(arguments)
                return await McpSpeakTool.execute(
                    arguments: parsed,
                    sink: sink,
                    diagnostics: diagnostics
                )
            } catch let error as CommandError {
                return McpToolCallResult(isError: true, message: error.description)
            } catch {
                return McpToolCallResult(isError: true, message: String(describing: error))
            }
        }

        while true {
            guard let body = reader.readFrame() else { break }
            guard
                let object = try? JSONSerialization.jsonObject(with: body),
                let request = object as? [String: Any]
            else {
                writeFrame(McpJSONRPC.parseErrorResponse())
                continue
            }
            if let response = await McpJSONRPC.handle(request: request, speak: speak) {
                writeFrame(response)
            }
        }
    }

    private func writeFrame(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        output.write(Data(header.utf8))
        output.write(data)
    }
}

/// Buffered Content-Length frame reader for MCP stdio.
private final class FrameReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns next JSON body, or nil on EOF.
    func readFrame() -> Data? {
        while true {
            if let headerEnd = indexOfHeaderTerminator(in: buffer) {
                let headerData = buffer.subdata(in: 0..<headerEnd)
                let bodyStart = headerEnd + 4 // \r\n\r\n
                guard let length = contentLength(from: headerData) else {
                    // Malformed headers — drop and stop.
                    return nil
                }
                while buffer.count < bodyStart + length {
                    guard let chunk = readChunk(), !chunk.isEmpty else {
                        return nil
                    }
                    buffer.append(chunk)
                }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
                buffer.removeSubrange(0..<(bodyStart + length))
                return body
            }

            guard let chunk = readChunk(), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    private func readChunk() -> Data? {
        do {
            return try handle.read(upToCount: 4096)
        } catch {
            return nil
        }
    }

    private func indexOfHeaderTerminator(in data: Data) -> Int? {
        let pattern = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        if let range = data.range(of: pattern) {
            return range.lowerBound
        }
        return nil
    }

    private func contentLength(from headerData: Data) -> Int? {
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        for line in header.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let raw = Int(value) else { return nil }
            return McpFraming.validatedContentLength(raw)
        }
        return nil
    }
}
