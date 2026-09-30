import Darwin
import Foundation

public enum DaemonProcessState: String, Codable, Equatable, Sendable {
    case missing
    case running
    case stale
    case invalid
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public let mode: DebriefMode
    public let muted: Bool
    public let companionEnabled: Bool
    public let process: DaemonProcessState
    public let socketPresent: Bool
    public let modelRevision: String?
    public let modelValid: Bool
    public let launchAgentInstalled: Bool
    public let hostSettingsReadable: [String: Bool]
    public let ownedHookCount: Int
    public let ownedSkillCount: Int
}

public struct DiagnosticFinding: Codable, Equatable, Sendable {
    public let code: String
    public let ok: Bool
    public let recovery: String?

    /// Short Korean line for `debrief doctor`.
    public var summaryLine: String {
        let status = ok ? "정상" : "문제"
        if let recovery, !ok {
            return "[\(status)] \(code) — \(recovery)"
        }
        return "[\(status)] \(code)"
    }
}

public struct CurrentError: Codable, Equatable, Sendable {
    public static let maximumMessageLength = 160
    public let timestamp: Date
    public let component: String
    public let code: String
    public let message: String
}

public struct Diagnostics: Sendable {
    private let paths: DebriefPaths
    private let processExists: @Sendable (Int32) -> Bool

    public init(home: URL, processExists: @escaping @Sendable (Int32) -> Bool = Diagnostics.liveProcessExists) {
        paths = DebriefPaths.forHome(home)
        self.processExists = processExists
    }

    public func status() -> StatusSnapshot {
        let configuration = DebriefConfiguration.load(from: paths.configURL)
        let process = processState()
        let model = modelState()
        let manifest = (try? InstallManifest.load(from: paths.installManifestURL)) ?? InstallManifest()
        let snapshot = StatusSnapshot(
            mode: configuration.mode,
            muted: configuration.muted,
            companionEnabled: configuration.companionEnabled,
            process: process,
            socketPresent: FileManager.default.fileExists(atPath: paths.socketURL.path),
            modelRevision: model.revision,
            modelValid: model.valid,
            launchAgentInstalled: FileManager.default.fileExists(atPath: paths.launchAgentURL.path),
            hostSettingsReadable: [
                HostSource.codex.rawValue:
                    settingsReadable(paths.home.appending(path: ".codex/hooks.json"))
                    && settingsReadableToml(paths.home.appending(path: ".codex/config.toml")),
                HostSource.claude.rawValue: settingsReadable(paths.home.appending(path: ".claude/settings.json")),
                HostSource.grok.rawValue: settingsReadableToml(paths.home.appending(path: ".grok/config.toml")),
            ],
            ownedHookCount: manifest.hooks.count,
            ownedSkillCount: manifest.files.count
        )
        return snapshot
    }

    /// CLI `debrief status` lines. Exits 0 even when the daemon is down.
    public func statusText() -> String {
        let snapshot = status()
        let process: String
        switch snapshot.process {
        case .running: process = "실행 중"
        case .missing: process = "없음"
        case .stale: process = "오래된 pid"
        case .invalid: process = "잘못된 pid"
        }
        let model: String
        if let revision = snapshot.modelRevision {
            model = snapshot.modelValid ? revision : "\(revision) (사용할 수 없음)"
        } else {
            model = "없음"
        }
        return """
        프로세스: \(process)
        음소거: \(snapshot.muted ? "켜짐" : "꺼짐")
        모드: \(snapshot.mode.rawValue)
        도우미 음성: \(snapshot.companionEnabled ? "켜짐" : "꺼짐")
        모델: \(model)
        소켓: \(snapshot.socketPresent ? "있음" : "없음")
        LaunchAgent: \(snapshot.launchAgentInstalled ? "설치됨" : "없음")
        """
    }

    public func doctor() -> [DiagnosticFinding] {
        let snapshot = status()
        let recovery = operationalRecovery(for: snapshot)
        var findings: [DiagnosticFinding] = []
        switch snapshot.process {
        case .running:
            findings.append(.init(code: "daemon.running", ok: true, recovery: nil))
        case .stale:
            findings.append(.init(code: "daemon.stale_pid", ok: false, recovery: recovery))
        case .invalid:
            findings.append(.init(code: "daemon.invalid_pid", ok: false, recovery: recovery))
        case .missing:
            findings.append(.init(code: "daemon.missing", ok: false, recovery: recovery))
        }
        if snapshot.modelRevision == nil {
            findings.append(.init(code: "model.missing", ok: false, recovery: recovery))
        } else if !snapshot.modelValid {
            findings.append(.init(code: "model.invalid_marker", ok: false, recovery: recovery))
        } else {
            findings.append(.init(code: "model.valid", ok: true, recovery: nil))
        }
        let mcpStatuses = hostMcpStatuses()
        let unreadableMcpHosts = Set(mcpStatuses.filter { $0.state == .unreadable }.map(\.host))
        for host in HostSource.allCases where snapshot.hostSettingsReadable[host.rawValue] == false {
            // Prefer single mcp.*.unreadable when the MCP probe already covers it.
            if unreadableMcpHosts.contains(host) { continue }
            findings.append(hostSettingsFinding(for: host))
        }
        for mcp in mcpStatuses where mcp.isProblem {
            findings.append(.init(
                code: mcp.doctorCode,
                ok: false,
                recovery: mcp.recovery
            ))
        }
        findings.append(.init(
            code: snapshot.socketPresent ? "socket.present" : "socket.missing",
            ok: snapshot.socketPresent,
            recovery: snapshot.socketPresent ? nil : recovery
        ))
        findings.append(.init(
            code: snapshot.launchAgentInstalled ? "launch_agent.installed" : "launch_agent.missing",
            ok: snapshot.launchAgentInstalled,
            recovery: snapshot.launchAgentInstalled ? nil : recovery
        ))
        if let error = currentError() {
            findings.append(.init(
                code: "last_error.\(error.code)",
                ok: false,
                recovery: error.message
            ))
        }
        return findings
    }

    /// First matching operational problem chooses the recovery command.
    private func operationalRecovery(for snapshot: StatusSnapshot) -> String {
        let modelBad = snapshot.modelRevision == nil || !snapshot.modelValid
        if !snapshot.launchAgentInstalled || modelBad {
            return "debrief install --repair"
        }
        if snapshot.process == .running && !snapshot.socketPresent {
            return "debrief install --repair"
        }
        if snapshot.process != .running && snapshot.launchAgentInstalled {
            return "debrief start"
        }
        return "debrief install --repair"
    }

    /// Failed findings only, for `debrief doctor`.
    public func doctorProblemLines(limit: Int = 8) -> [String] {
        let problems = doctor().filter { !$0.ok }
        return Array(problems.prefix(limit).map(\.summaryLine))
    }

    /// Full plain-text doctor report for pasteboard copy.
    public func doctorReportText() -> String {
        let lines = doctor().map(\.summaryLine)
        var body = "debrief 진단 (\(DebriefVersion.current))\n"
        body += lines.joined(separator: "\n")
        if lines.isEmpty {
            body += "(결과 없음)"
        }
        return body
    }

    /// Per-host debrief MCP wiring (Claude / Codex / Grok).
    public func hostMcpStatuses() -> [HostMcpStatus] {
        HostMcpProbe.statuses(home: paths.home, expectedExecutable: paths.executableURL)
    }

    public func recordError(component: String, code: String, message: String) throws {
        let normalized = message
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = CurrentError(
            timestamp: Date(),
            component: String(component.prefix(64)),
            code: String(code.prefix(64)),
            message: String(normalized.prefix(CurrentError.maximumMessageLength))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicInstallerFile.write(try encoder.encode(value), to: paths.lastErrorURL, permissions: 0o600)
    }

    /// Reads the most recent bounded error, if any.
    public func currentError() -> CurrentError? {
        guard let data = try? Data(contentsOf: paths.lastErrorURL),
              let value = try? JSONDecoder().decode(CurrentError.self, from: data)
        else {
            return nil
        }
        return value
    }

    /// Removes a prior error after a successful recovery (service start / hook delivery).
    public func clearCurrentError() throws {
        let url = paths.lastErrorURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func liveProcessExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func processState() -> DaemonProcessState {
        guard let data = try? Data(contentsOf: paths.pidURL),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw), pid > 0 else {
            return FileManager.default.fileExists(atPath: paths.pidURL.path) ? .invalid : .missing
        }
        return processExists(pid) ? .running : .stale
    }

    private func modelState() -> (revision: String?, valid: Bool) {
        guard let installed = try? InstalledModel.resolveCurrent(in: paths.modelsDirectory) else {
            return (nil, false)
        }
        let marker = installed.directory.appending(path: ".validated.json")
        guard let data = try? Data(contentsOf: marker),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              manifest.revision == installed.revision,
              manifest == ModelManifest.supertonic3,
              (try? manifest.validate()) != nil else {
            return (installed.revision, false)
        }
        return (installed.revision, true)
    }

    private func settingsReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        return true
    }

    /// Grok config is TOML: missing file is ok; UTF-8 readable is ok (no JSON parse).
    private func settingsReadableToml(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? String(contentsOf: url, encoding: .utf8)) != nil
    }

    /// Host-aware doctor code: JSON hosts use invalid_json; TOML hosts use invalid_toml.
    private func hostSettingsFinding(for host: HostSource) -> DiagnosticFinding {
        switch host {
        case .grok:
            return .init(
                code: "host.grok.invalid_toml",
                ok: false,
                recovery: "repair ~/.grok/config.toml as UTF-8 TOML, then run debrief install --grok --repair"
            )
        case .codex:
            // Prefer specific code: hooks.json JSON vs config.toml UTF-8.
            let hooksOK = settingsReadable(paths.home.appending(path: ".codex/hooks.json"))
            if !hooksOK {
                return .init(
                    code: "host.codex.invalid_json",
                    ok: false,
                    recovery: "repair ~/.codex/hooks.json, then run debrief install --codex --repair"
                )
            }
            return .init(
                code: "host.codex.invalid_toml",
                ok: false,
                recovery: "repair ~/.codex/config.toml as UTF-8 TOML, then run debrief install --codex --repair"
            )
        case .claude:
            return .init(
                code: "host.claude.invalid_json",
                ok: false,
                recovery: "repair the host JSON, then run debrief install --claude --repair"
            )
        }
    }
}
