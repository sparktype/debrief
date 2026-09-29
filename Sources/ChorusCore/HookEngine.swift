import Foundation

public struct HookResult: Sendable {
    public let stdout: Data
    public let submitted: Bool
    /// Human-readable delivery problem for diagnostics (nil when healthy).
    public let deliveryError: String?

    public init(stdout: Data, submitted: Bool, deliveryError: String? = nil) {
        self.stdout = stdout
        self.submitted = submitted
        self.deliveryError = deliveryError
    }
}

public struct HookEngine: Sendable {
    private let sink: any SpeechSink

    public init(sink: any SpeechSink) {
        self.sink = sink
    }

    public func handle(_ event: HookEvent, source: HostSource) async -> HookResult {
        // Keep sink retained for API stability; speech delivery moved to MCP speak tool.
        _ = sink
        switch event.name {
        case .sessionStart, .userPromptSubmit, .subagentStart:
            // Host- and event-aware speak contract (Claude tool name + subagent priority).
            let context = VoiceCatalog.context(for: event, source: source)
            let stdout = (try? HookAdapter.contextOutput(context, source: source, event: event))
                ?? Data("{}".utf8)
            return HookResult(stdout: stdout, submitted: false)

        case .stop, .subagentStop:
            let success = (try? HookAdapter.successOutput(source: source, event: event))
                ?? Data("{}".utf8)
            return HookResult(stdout: success, submitted: false)
        }
    }
}
