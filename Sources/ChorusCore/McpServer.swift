// MCP stdio JSON-RPC 서버 (speak + install 도구)
import Darwin
import Foundation

/// Pure JSON-RPC method dispatch for MCP (testable without FileHandle).
public enum McpJSONRPC {
    public static func handle(
        request: [String: Any],
        callTool: @escaping @Sendable (String, [String: Any]) async -> McpToolCallResult
    ) async -> [String: Any]? {
        let method = request["method"] as? String
        let id = request["id"]

        // Notifications (no id) return no response body.
        if id == nil {
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
            return nil

        case "tools/list":
            return successResponse(id: id, result: [
                "tools": [speakToolDefinition(), installToolDefinition()],
            ] as [String: Any])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String
            guard let name, ["speak", "install"].contains(name) else {
                return errorResponse(
                    id: id,
                    code: -32601,
                    message: "Method not found: tool \(name ?? "(nil)")"
                )
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let toolResult = await callTool(name, arguments)
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

    /// Compatibility wrapper used by older unit tests that only exercise `speak`.
    public static func handle(
        request: [String: Any],
        speak: @escaping @Sendable ([String: Any]) async -> McpToolCallResult
    ) async -> [String: Any]? {
        await handle(request: request, callTool: { name, arguments in
            guard name == "speak" else {
                return McpToolCallResult(isError: true, message: "unknown tool")
            }
            return await speak(arguments)
        })
    }

    private static func speakToolDefinition() -> [String: Any] {
        [
            "name": "speak",
            "description":
                "Speak a short reflective companion line when speech helps; silence is OK when it does not. "
                + "Prefer observation + meaning + one next step (not file lists). "
                + "lane=companion (default, prefer voice F1) or work; emotion biases prosody only. "
                + "On Claude Code: mcp__chorus__speak; on Grok: chorus__speak (search_tool/use_tool). "
                + "Do not put HTML comments or JSON speech metadata in the assistant message body.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"] as [String: Any],
                    "voice": ["type": "string"] as [String: Any],
                    "speed": ["type": "number"] as [String: Any],
                    "volume": ["type": "number"] as [String: Any],
                    "priority": [
                        "type": "string",
                        "description": "main (default) or subagent; focus/quiet/night suppress subagent",
                        "enum": ["main", "subagent"],
                    ] as [String: Any],
                    "lane": [
                        "type": "string",
                        "description": "companion (default reflective) or work (factual report)",
                        "enum": ["companion", "work"],
                    ] as [String: Any],
                    "emotion": [
                        "type": "string",
                        "description":
                            "restrained affect for companion: neutral (default), warm, focused, concerned, relieved, tired",
                        "enum": ["neutral", "warm", "focused", "concerned", "relieved", "tired"],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["text", "voice", "speed", "volume"],
            ] as [String: Any],
        ]
    }

    private static func installToolDefinition() -> [String: Any] {
        [
            "name": "install",
            "description":
                "Install or repair Chorus.app host integration (MCP registration, start-family hooks, skills, LaunchAgent). "
                + "On Claude Code this may appear as mcp__chorus__install; on Grok as chorus__install "
                + "(search_tool / use_tool). "
                + "Prefer repair=true for fixes. First-time model download can be slow — use shell install if the tool times out. "
                + "After install: Claude restart; Grok run /mcps to refresh tools.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "hosts": [
                        "type": "array",
                        "description": "Hosts to wire: codex, claude, grok. Omit for all.",
                        "items": [
                            "type": "string",
                            "enum": ["codex", "claude", "grok"],
                        ] as [String: Any],
                    ] as [String: Any],
                    "repair": [
                        "type": "boolean",
                        "description": "Reinstall owned files and re-verify model (default true).",
                    ] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
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

    public static func validatedContentLength(_ length: Int) -> Int? {
        guard length >= 0, length <= maxContentLength else { return nil }
        return length
    }
}

public enum McpWireFormat: Sendable, Equatable {
    case contentLength
    case newlineDelimited
}

/// Host-spawned stdio MCP server; tools: speak + install.
public struct McpServer: Sendable {
    private let home: URL
    private let sink: any SpeechSink
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: Diagnostics
    private let sourceExecutable: URL
    private let installRunner: (any McpInstallRunning)?

    public init(
        home: URL,
        sink: (any SpeechSink)? = nil,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        sourceExecutable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
        installRunner: (any McpInstallRunning)? = nil
    ) {
        self.home = home
        let paths = ChorusPaths.forHome(home)
        self.sink = sink ?? UnixSocketClient(socketURL: paths.socketURL)
        self.input = input
        self.output = output
        self.diagnostics = Diagnostics(home: home)
        self.sourceExecutable = sourceExecutable
        self.installRunner = installRunner
    }

    public func run() async {
        let reader = FrameReader(handle: input)
        let sink = self.sink
        let diagnostics = self.diagnostics
        let home = self.home
        let sourceExecutable = self.sourceExecutable
        let installRunner = self.installRunner
            ?? LiveMcpInstallRunner(home: home, sourceExecutable: sourceExecutable)

        let callTool: @Sendable (String, [String: Any]) async -> McpToolCallResult = { name, arguments in
            switch name {
            case "speak":
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
            case "install":
                do {
                    let parsed = try McpInstallTool.parseArguments(arguments)
                    return await McpInstallTool.execute(
                        arguments: parsed,
                        runner: installRunner,
                        diagnostics: diagnostics
                    )
                } catch let error as CommandError {
                    return McpToolCallResult(isError: true, message: error.description)
                } catch {
                    return McpToolCallResult(isError: true, message: String(describing: error))
                }
            default:
                return McpToolCallResult(isError: true, message: "unknown tool")
            }
        }

        var wireFormat: McpWireFormat = .contentLength
        while true {
            guard let frame = reader.readFrame() else { break }
            wireFormat = frame.format
            guard
                let object = try? JSONSerialization.jsonObject(with: frame.body),
                let request = object as? [String: Any]
            else {
                writeFrame(McpJSONRPC.parseErrorResponse(), format: wireFormat)
                continue
            }
            if let response = await McpJSONRPC.handle(request: request, callTool: callTool) {
                writeFrame(response, format: wireFormat)
            }
        }
    }

    private func writeFrame(_ object: [String: Any], format: McpWireFormat) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        switch format {
        case .contentLength:
            let header = "Content-Length: \(data.count)\r\n\r\n"
            output.write(Data(header.utf8))
            output.write(data)
        case .newlineDelimited:
            data.append(0x0A)
            output.write(data)
        }
    }
}

private final class FrameReader: @unchecked Sendable {
    struct Frame {
        let body: Data
        let format: McpWireFormat
    }

    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readFrame() -> Frame? {
        while true {
            if let frame = tryExtractFrame() {
                return frame
            }
            guard let chunk = readChunk(), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    private func tryExtractFrame() -> Frame? {
        skipLeadingWhitespace()
        guard let first = buffer.first else { return nil }

        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
            let end = nl
            let bodyEnd: Data.Index
            if end > buffer.startIndex, buffer[buffer.index(before: end)] == 0x0D {
                bodyEnd = buffer.index(before: end)
            } else {
                bodyEnd = end
            }
            let body = buffer.subdata(in: buffer.startIndex..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex...end)
            guard !body.isEmpty else { return nil }
            return Frame(body: body, format: .newlineDelimited)
        }

        guard let headerEnd = indexOfHeaderTerminator(in: buffer) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd)
        let bodyStart = headerEnd + 4
        guard let length = contentLength(from: headerData) else {
            buffer.removeAll()
            return nil
        }
        guard buffer.count >= bodyStart + length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(0..<(bodyStart + length))
        return Frame(body: body, format: .contentLength)
    }

    private func skipLeadingWhitespace() {
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let b = buffer[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                i = buffer.index(after: i)
            } else {
                break
            }
        }
        if i > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<i)
        }
    }

    private func readChunk() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if n > 0 {
                return Data(bytes.prefix(n))
            }
            if n == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    }

    private func indexOfHeaderTerminator(in data: Data) -> Int? {
        let pattern = Data([0x0D, 0x0A, 0x0D, 0x0A])
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
