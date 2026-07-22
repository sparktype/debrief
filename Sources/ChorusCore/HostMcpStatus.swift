// 에이전트별 MCP 배선 상태 probe (메뉴바 · 진단)
import Foundation

/// On-disk chorus MCP registration state for one agent host.
public enum HostMcpState: String, Codable, Equatable, Sendable {
    case ok
    case missing
    case absent
    case unreadable
    case stalePath
}

/// Snapshot of one host's MCP wiring for menu and doctor.
public struct HostMcpStatus: Equatable, Sendable {
    public let host: HostSource
    public let state: HostMcpState

    public init(host: HostSource, state: HostMcpState) {
        self.host = host
        self.state = state
    }

    public var isProblem: Bool {
        switch state {
        case .ok, .absent: return false
        case .missing, .unreadable, .stalePath: return true
        }
    }

    /// Leading Unicode emoji for the state (menu chrome).
    public var stateEmoji: String {
        switch state {
        case .ok: return "✅"
        case .absent: return "⚪"
        case .missing: return "⚠️"
        case .unreadable: return "❌"
        case .stalePath: return "🔄"
        }
    }

    public var hostDisplayName: String {
        switch host {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    public var stateLabel: String {
        switch state {
        case .ok: return "등록됨"
        case .absent: return "설정 없음"
        case .missing: return "미등록"
        case .unreadable: return "설정 읽기 실패"
        case .stalePath: return "경로 불일치"
        }
    }

    /// Full menu line: `{emoji} {Host}: {label}`.
    public var menuLine: String {
        "\(stateEmoji) \(hostDisplayName): \(stateLabel)"
    }

    /// Recovery hint for doctor (nil when not a problem).
    public var recovery: String? {
        guard isProblem else { return nil }
        let flag: String
        switch host {
        case .claude: flag = "--claude"
        case .codex: flag = "--codex"
        case .grok: flag = "--grok"
        }
        switch state {
        case .unreadable:
            return "에이전트 설정을 수정한 뒤 메뉴에서 복구하거나 chorus install \(flag) --repair"
        case .missing, .stalePath:
            return "메뉴 「문제 에이전트 복구」 또는 chorus install \(flag) --repair"
        case .ok, .absent:
            return nil
        }
    }

    public var doctorCode: String {
        "mcp.\(host.rawValue).\(state.rawValue)"
    }
}

/// Pure filesystem probe for host MCP registration.
public enum HostMcpProbe {
    public static func statuses(home: URL, expectedExecutable: URL) -> [HostMcpStatus] {
        HostSource.allCases.map { status(for: $0, home: home, expectedExecutable: expectedExecutable) }
    }

    public static func problemHosts(home: URL, expectedExecutable: URL) -> Set<HostSource> {
        Set(
            statuses(home: home, expectedExecutable: expectedExecutable)
                .filter(\.isProblem)
                .map(\.host)
        )
    }

    public static func status(
        for host: HostSource,
        home: URL,
        expectedExecutable: URL
    ) -> HostMcpStatus {
        let state: HostMcpState
        switch host {
        case .claude:
            state = probeClaude(home: home, expected: expectedExecutable)
        case .codex:
            state = probeToml(
                configURL: home.appending(path: ".codex/config.toml"),
                expected: expectedExecutable
            )
        case .grok:
            state = probeToml(
                configURL: home.appending(path: ".grok/config.toml"),
                expected: expectedExecutable
            )
        }
        return HostMcpStatus(host: host, state: state)
    }

    // MARK: - Claude JSON

    private static func probeClaude(home: URL, expected: URL) -> HostMcpState {
        let url = home.appending(path: ".claude/settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }

        guard let mcpServers = root["mcpServers"] as? [String: Any],
              let chorus = mcpServers["chorus"] as? [String: Any]
        else { return .missing }

        guard let command = chorus["command"] as? String, !command.isEmpty else {
            return .missing
        }
        return pathsMatch(command, expected) ? .ok : .stalePath
    }

    // MARK: - Codex / Grok TOML

    private static func probeToml(configURL: URL, expected: URL) -> HostMcpState {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .absent }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .unreadable
        }

        let tableBody: String?
        if let owned = McpTomlConfig.ownedFragment(in: text),
           McpTomlConfig.hasChorusTable(owned) || owned.contains("mcp_servers.chorus") {
            tableBody = owned
        } else if McpTomlConfig.hasChorusTable(text) {
            tableBody = text
        } else {
            return .missing
        }

        guard let command = extractTomlCommand(from: tableBody ?? "") else {
            return .missing
        }
        return pathsMatch(command, expected) ? .ok : .stalePath
    }

    /// Best-effort `command = "..."` from a TOML fragment.
    private static func extractTomlCommand(from text: String) -> String? {
        // Prefer the value under [mcp_servers.chorus] when the whole file is scanned.
        let section: String
        if let range = text.range(of: #"[mcp_servers\.chorus]"#, options: .regularExpression) {
            section = String(text[range.lowerBound...])
        } else {
            section = text
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*command\s*=\s*"((?:\\.|[^"\\])*)""#,
            options: [.anchorsMatchLines]
        ) else { return nil }
        let ns = section as NSString
        guard let match = regex.firstMatch(in: section, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: section)
        else { return nil }
        return unescapeTomlString(String(section[r]))
    }

    private static func unescapeTomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func pathsMatch(_ command: String, _ expected: URL) -> Bool {
        let left = URL(fileURLWithPath: command).resolvingSymlinksInPath().standardizedFileURL.path
        let right = expected.resolvingSymlinksInPath().standardizedFileURL.path
        return left == right
    }
}
