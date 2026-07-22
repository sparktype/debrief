import Darwin
import Foundation

public enum DaemonProcessState: String, Codable, Equatable, Sendable {
    case missing
    case running
    case stale
    case invalid
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public let mode: ChorusMode
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

    /// Short Korean line for the menu bar diagnostics submenu.
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
    private let paths: ChorusPaths
    private let processExists: @Sendable (Int32) -> Bool

    public init(home: URL, processExists: @escaping @Sendable (Int32) -> Bool = Diagnostics.liveProcessExists) {
        paths = ChorusPaths.forHome(home)
        self.processExists = processExists
    }

    public func status() -> StatusSnapshot {
        let configuration = ChorusConfiguration.load(from: paths.configURL)
        let process = processState()
        let model = modelState()
        let manifest = (try? InstallManifest.load(from: paths.installManifestURL)) ?? InstallManifest()
        return StatusSnapshot(
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
    }

    public func doctor() -> [DiagnosticFinding] {
        let snapshot = status()
        var findings: [DiagnosticFinding] = []
        switch snapshot.process {
        case .running:
            findings.append(.init(code: "daemon.running", ok: true, recovery: nil))
        case .stale:
            findings.append(.init(code: "daemon.stale_pid", ok: false, recovery: "chorus install --repair"))
        case .invalid:
            findings.append(.init(code: "daemon.invalid_pid", ok: false, recovery: "chorus install --repair"))
        case .missing:
            findings.append(.init(code: "daemon.missing", ok: false, recovery: "chorus install --repair"))
        }
        if snapshot.modelRevision == nil {
            findings.append(.init(code: "model.missing", ok: false, recovery: "chorus install --repair"))
        } else if !snapshot.modelValid {
            findings.append(.init(code: "model.invalid_marker", ok: false, recovery: "chorus install --repair"))
        } else {
            findings.append(.init(code: "model.valid", ok: true, recovery: nil))
        }
        for host in HostSource.allCases where snapshot.hostSettingsReadable[host.rawValue] == false {
            findings.append(hostSettingsFinding(for: host))
        }
        let socketRecovery: String?
        if snapshot.socketPresent {
            socketRecovery = nil
        } else if snapshot.process == .running {
            // Host alive (e.g. menu Stop) — restart service, not full install repair.
            socketRecovery = "Start service from menu, or run chorus menubar"
        } else {
            socketRecovery = "chorus install --repair"
        }
        findings.append(.init(
            code: snapshot.socketPresent ? "socket.present" : "socket.missing",
            ok: snapshot.socketPresent,
            recovery: socketRecovery
        ))
        findings.append(.init(
            code: snapshot.launchAgentInstalled ? "launch_agent.installed" : "launch_agent.missing",
            ok: snapshot.launchAgentInstalled,
            recovery: snapshot.launchAgentInstalled ? nil : "chorus install --repair"
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

    /// Failed findings only, newest last-error first when present, for menu display.
    public func doctorProblemLines(limit: Int = 8) -> [String] {
        let problems = doctor().filter { !$0.ok }
        return Array(problems.prefix(limit).map(\.summaryLine))
    }

    /// Full plain-text doctor report for pasteboard copy.
    public func doctorReportText() -> String {
        let lines = doctor().map(\.summaryLine)
        var body = "Chorus 진단 (\(ChorusVersion.current))\n"
        body += lines.joined(separator: "\n")
        if lines.isEmpty {
            body += "(결과 없음)"
        }
        return body
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
                recovery: "repair ~/.grok/config.toml as UTF-8 TOML, then run chorus install --grok --repair"
            )
        case .codex:
            // Prefer specific code: hooks.json JSON vs config.toml UTF-8.
            let hooksOK = settingsReadable(paths.home.appending(path: ".codex/hooks.json"))
            if !hooksOK {
                return .init(
                    code: "host.codex.invalid_json",
                    ok: false,
                    recovery: "repair ~/.codex/hooks.json, then run chorus install --codex --repair"
                )
            }
            return .init(
                code: "host.codex.invalid_toml",
                ok: false,
                recovery: "repair ~/.codex/config.toml as UTF-8 TOML, then run chorus install --codex --repair"
            )
        case .claude:
            return .init(
                code: "host.claude.invalid_json",
                ok: false,
                recovery: "repair the host JSON, then run chorus install --claude --repair"
            )
        }
    }
}
