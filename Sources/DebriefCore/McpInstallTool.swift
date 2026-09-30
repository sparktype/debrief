// MCP install 도구 — 호스트 MCP/훅 등록·복구 (Claude/Codex/Grok)
import Foundation

public struct McpInstallArguments: Equatable, Sendable {
    /// Empty set means all hosts (same as CLI with no host flags).
    public let hosts: Set<HostSource>
    public let repair: Bool

    public init(hosts: Set<HostSource>, repair: Bool) {
        self.hosts = hosts
        self.repair = repair
    }
}

/// Injectable installer for MCP `install` (tests avoid real model download).
public protocol McpInstallRunning: Sendable {
    func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult
}

public struct LiveMcpInstallRunner: McpInstallRunning {
    private let home: URL
    private let sourceExecutable: URL

    public init(home: URL, sourceExecutable: URL) {
        self.home = home
        self.sourceExecutable = sourceExecutable
    }

    public func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult {
        let paths = DebriefPaths.forHome(home)
        let runtime = RuntimeInstaller(
            home: home,
            sourceExecutable: sourceExecutable,
            modelInstaller: ModelInstaller(
                modelsDirectory: paths.modelsDirectory,
                manifest: .supertonic3,
                downloader: URLSessionModelDownloader()
            ),
            launchctl: ProcessLaunchctlRunner()
        )
        return try await runtime.install(hosts: hosts, repair: repair)
    }
}

public enum McpInstallTool {
    public static func parseArguments(_ object: [String: Any]) throws -> McpInstallArguments {
        let repair: Bool
        if object["repair"] == nil {
            repair = true
        } else if let b = object["repair"] as? Bool {
            repair = b
        } else if let n = object["repair"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            repair = n.boolValue
        } else {
            throw CommandError.usage("install repair must be a boolean")
        }

        let hosts: Set<HostSource>
        if object["hosts"] == nil {
            hosts = Set(HostSource.allCases)
        } else if let list = object["hosts"] as? [String] {
            var parsed = Set<HostSource>()
            for raw in list {
                guard let host = HostSource(rawValue: raw) else {
                    throw CommandError.usage(
                        "install hosts entries must be codex, claude, or grok (got \(raw))"
                    )
                }
                parsed.insert(host)
            }
            guard !parsed.isEmpty else {
                throw CommandError.usage("install hosts must not be empty")
            }
            hosts = parsed
        } else if let single = object["hosts"] as? String,
                  let host = HostSource(rawValue: single) {
            hosts = [host]
        } else {
            throw CommandError.usage("install hosts must be an array of host names")
        }

        return McpInstallArguments(hosts: hosts, repair: repair)
    }

    public static func execute(
        arguments: McpInstallArguments,
        runner: any McpInstallRunning,
        diagnostics: Diagnostics
    ) async -> McpToolCallResult {
        do {
            let result = try await runner.install(hosts: arguments.hosts, repair: arguments.repair)
            try? diagnostics.clearCurrentError()
            var payload: [String: Any] = [
                "ok": true,
                "hosts": arguments.hosts.map(\.rawValue).sorted(),
                "repair": arguments.repair,
                "codexReviewRequired": result.codexReviewRequired,
            ]
            if !result.preservedModifiedFiles.isEmpty {
                payload["preserved"] = result.preservedModifiedFiles
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let message = String(decoding: data, as: UTF8.self)
            return McpToolCallResult(isError: false, message: message)
        } catch {
            let short = String(describing: error)
            try? diagnostics.recordError(
                component: "mcp",
                code: "install_failed",
                message: "mcp install: \(short)"
            )
            return McpToolCallResult(
                isError: true,
                message: "설치에 실패했습니다: \(String(short.prefix(120)))"
            )
        }
    }
}
