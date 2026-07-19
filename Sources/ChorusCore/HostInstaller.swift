import Foundation

public enum HostInstallerError: Error, Equatable, Sendable {
    case settingsRootMustBeObject
    case hooksMustBeObject
    case eventHooksMustBeArray(String)
}

public struct HostInstallResult: Equatable, Sendable {
    public let codexReviewRequired: Bool
    public let preservedModifiedFiles: [String]
}

/// Marker-wrapped TOML MCP table body for Codex / Grok `config.toml`.
enum McpTomlConfig {
    static let begin = "# BEGIN chorus-mcp"
    static let end = "# END chorus-mcp"

    static func upsert(existing: String, fragment: String) -> String {
        let block = "\(begin)\n\(fragment.trimmingCharacters(in: .newlines))\n\(end)\n"
        if let range = existing.range(of: #"\#(begin)[\s\S]*?\#(end)\n?"#, options: .regularExpression) {
            return existing.replacingCharacters(in: range, with: block)
        }
        var base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { base += "\n\n" }
        return base + block
    }

    static func removeOwned(_ existing: String) -> String {
        existing.replacingOccurrences(
            of: #"\#(begin)[\s\S]*?\#(end)\n?"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Inner fragment between ownership markers, if present.
    static func ownedFragment(in existing: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\#(begin)\n([\s\S]*?)\n\#(end)"#,
            options: []
        ) else { return nil }
        let ns = existing as NSString
        guard let match = regex.firstMatch(in: existing, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: existing)
        else { return nil }
        return String(existing[range])
    }

    static func hasMarkers(_ existing: String) -> Bool {
        existing.contains(begin) && existing.contains(end)
    }

    static func hasChorusTable(_ existing: String) -> Bool {
        existing.range(of: #"\[mcp_servers\.chorus\]"#, options: .regularExpression) != nil
    }
}

public struct HostInstaller: Sendable {
    private let home: URL
    private let executable: URL
    private let manifestURL: URL

    public init(home: URL, executable: URL, manifestURL: URL? = nil) {
        self.home = home
        self.executable = executable
        self.manifestURL = manifestURL ?? ChorusPaths.forHome(home).installManifestURL
    }

    /// Synthetic ownership path for JSON/TOML MCP registration digests.
    static func mcpOwnershipPath(for host: HostSource) -> String {
        "mcp:\(host.rawValue):chorus"
    }

    @discardableResult
    public func install(hosts: Set<HostSource>) throws -> HostInstallResult {
        var manifest = try InstallManifest.load(from: manifestURL)
        var preserved: [String] = []

        for host in hosts.sorted(by: { $0.rawValue < $1.rawValue }) {
            let previousFiles = manifest.files.filter { $0.host == host }
            let previousHooks = manifest.hooks.filter { $0.host == host }
            var ownedHooks: [OwnedHook] = []
            var ownedFiles: [OwnedInstalledFile] = []

            switch host {
            case .codex:
                try installJSONHost(
                    host,
                    includeJSONMcp: false,
                    previousFiles: previousFiles,
                    previousHooks: previousHooks,
                    ownedHooks: &ownedHooks,
                    ownedFiles: &ownedFiles,
                    preserved: &preserved
                )
                try installTomlMcp(
                    host: .codex,
                    previousFiles: previousFiles,
                    ownedFiles: &ownedFiles,
                    preserved: &preserved
                )
            case .claude:
                try installJSONHost(
                    host,
                    includeJSONMcp: true,
                    previousFiles: previousFiles,
                    previousHooks: previousHooks,
                    ownedHooks: &ownedHooks,
                    ownedFiles: &ownedFiles,
                    preserved: &preserved
                )
            case .grok:
                try installGrokHost(
                    previousFiles: previousFiles,
                    ownedFiles: &ownedFiles,
                    preserved: &preserved
                )
            }

            manifest.hooks.removeAll { $0.host == host }
            manifest.hooks.append(contentsOf: ownedHooks)
            manifest.files.removeAll { $0.host == host }
            manifest.files.append(contentsOf: ownedFiles)
        }
        try manifest.save(to: manifestURL)
        return HostInstallResult(
            codexReviewRequired: hosts.contains(.codex),
            preservedModifiedFiles: preserved.sorted()
        )
    }

    @discardableResult
    public func uninstall(hosts: Set<HostSource>) throws -> HostInstallResult {
        var manifest = try InstallManifest.load(from: manifestURL)
        var preserved: [String] = []

        for host in hosts.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch host {
            case .codex:
                try uninstallJSONHost(
                    host,
                    removeJSONMcp: false,
                    stripLegacyJSONMcp: true,
                    manifest: manifest,
                    preserved: &preserved
                )
                try uninstallTomlMcp(host: .codex, manifest: manifest, preserved: &preserved)
            case .claude:
                try uninstallJSONHost(
                    host,
                    removeJSONMcp: true,
                    stripLegacyJSONMcp: false,
                    manifest: manifest,
                    preserved: &preserved
                )
            case .grok:
                try uninstallGrokHost(manifest: manifest, preserved: &preserved)
            }
            manifest.hooks.removeAll { $0.host == host }
            manifest.files.removeAll { $0.host == host }
        }
        try manifest.save(to: manifestURL)
        return HostInstallResult(codexReviewRequired: false, preservedModifiedFiles: preserved.sorted())
    }

    // MARK: - JSON hosts (Codex hooks / Claude settings)

    private func installJSONHost(
        _ host: HostSource,
        includeJSONMcp: Bool,
        previousFiles: [OwnedInstalledFile],
        previousHooks: [OwnedHook],
        ownedHooks: inout [OwnedHook],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        let settingsURL = settingsURL(for: host)
        var root = try readSettings(at: settingsURL)
        var hooks = try hooksObject(from: root)

        // Drop previously owned Stop/SubagentStop (and any other retired events) on repair.
        let activeEvents = Set(EmbeddedTemplates.hookEvents)
        for owned in previousHooks where !activeEvents.contains(owned.event) {
            var entries = try eventEntries(owned.event, from: hooks)
            entries.removeAll { entry in
                (try? InstallerDigest.json(entry)) == owned.sha256
            }
            if entries.isEmpty { hooks.removeValue(forKey: owned.event.rawValue) }
            else { hooks[owned.event.rawValue] = entries }
        }

        for event in EmbeddedTemplates.hookEvents {
            let entry = EmbeddedTemplates.hookEntry(executable: executable, source: host)
            let object = try jsonObject(entry)
            let digest = try InstallerDigest.json(object)
            var entries = try eventEntries(event, from: hooks)
            if try !entries.contains(where: { try InstallerDigest.json($0) == digest }) {
                entries.append(object)
            }
            hooks[event.rawValue] = entries
            ownedHooks.append(OwnedHook(host: host, event: event, sha256: digest))
        }
        root["hooks"] = hooks

        if includeJSONMcp {
            try mergeJSONMcp(
                into: &root,
                host: host,
                previousFiles: previousFiles,
                ownedFiles: &ownedFiles,
                preserved: &preserved
            )
        } else if host == .codex {
            // Repair: strip previously owned JSON mcpServers.chorus from hooks.json.
            try stripLegacyJSONMcpIfOwned(from: &root, host: host, previousFiles: previousFiles)
        }

        try backupIfNeeded(settingsURL)
        try writeSettings(root, to: settingsURL)

        try installSkills(
            for: host,
            previousFiles: previousFiles,
            ownedFiles: &ownedFiles,
            preserved: &preserved
        )
    }

    private func mergeJSONMcp(
        into root: inout [String: Any],
        host: HostSource,
        previousFiles: [OwnedInstalledFile],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        let mcpPath = Self.mcpOwnershipPath(for: host)
        let registration = EmbeddedTemplates.mcpRegistration(executable: executable)
        let digest = try InstallerDigest.json(registration)
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]

        if let existing = mcpServers["chorus"] {
            let current = try InstallerDigest.json(existing)
            let previouslyOwned = previousFiles.contains { $0.path == mcpPath && $0.sha256 == current }
            if current != digest, !previouslyOwned {
                preserved.append(mcpPath)
                if let previous = previousFiles.first(where: { $0.path == mcpPath }) {
                    ownedFiles.append(previous)
                }
            } else {
                mcpServers["chorus"] = registration
                ownedFiles.append(OwnedInstalledFile(host: host, path: mcpPath, sha256: digest))
            }
        } else {
            mcpServers["chorus"] = registration
            ownedFiles.append(OwnedInstalledFile(host: host, path: mcpPath, sha256: digest))
        }
        root["mcpServers"] = mcpServers
    }

    /// Remove owned JSON `mcpServers.chorus` left in Codex hooks.json by older installs.
    private func stripLegacyJSONMcpIfOwned(
        from root: inout [String: Any],
        host: HostSource,
        previousFiles: [OwnedInstalledFile]
    ) throws {
        guard var mcpServers = root["mcpServers"] as? [String: Any],
              let existing = mcpServers["chorus"] else { return }
        let mcpPath = Self.mcpOwnershipPath(for: host)
        let current = try InstallerDigest.json(existing)
        let registrationDigest = try InstallerDigest.json(
            EmbeddedTemplates.mcpRegistration(executable: executable)
        )
        let wasOwned = previousFiles.contains { $0.path == mcpPath && $0.sha256 == current }
        if current == registrationDigest || wasOwned {
            mcpServers.removeValue(forKey: "chorus")
            root["mcpServers"] = mcpServers
        }
    }

    private func uninstallJSONHost(
        _ host: HostSource,
        removeJSONMcp: Bool,
        stripLegacyJSONMcp: Bool,
        manifest: InstallManifest,
        preserved: inout [String]
    ) throws {
        let settingsURL = settingsURL(for: host)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            var root = try readSettings(at: settingsURL)
            var hooks = try hooksObject(from: root)
            for owned in manifest.hooks where owned.host == host {
                var entries = try eventEntries(owned.event, from: hooks)
                entries.removeAll { entry in
                    (try? InstallerDigest.json(entry)) == owned.sha256
                }
                if entries.isEmpty { hooks.removeValue(forKey: owned.event.rawValue) }
                else { hooks[owned.event.rawValue] = entries }
            }
            root["hooks"] = hooks

            let mcpPath = Self.mcpOwnershipPath(for: host)
            if removeJSONMcp,
               let owned = manifest.files.first(where: { $0.host == host && $0.path == mcpPath }),
               var mcpServers = root["mcpServers"] as? [String: Any] {
                if let existing = mcpServers["chorus"],
                   (try? InstallerDigest.json(existing)) == owned.sha256 {
                    mcpServers.removeValue(forKey: "chorus")
                    root["mcpServers"] = mcpServers
                } else if mcpServers["chorus"] != nil {
                    preserved.append(mcpPath)
                }
            } else if stripLegacyJSONMcp {
                let previous = manifest.files.filter { $0.host == host }
                try stripLegacyJSONMcpIfOwned(from: &root, host: host, previousFiles: previous)
            }

            try writeSettings(root, to: settingsURL)
        }

        for owned in manifest.files where owned.host == host {
            if owned.path.hasPrefix("mcp:") { continue }
            try removeOwnedFile(owned, preserved: &preserved)
        }
    }

    // MARK: - TOML MCP (Codex config.toml / Grok config.toml)

    private func installTomlMcp(
        host: HostSource,
        previousFiles: [OwnedInstalledFile],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        let configURL = mcpTomlConfigURL(for: host)
        let mcpPath = Self.mcpOwnershipPath(for: host)
        let fragment = EmbeddedTemplates.mcpTomlFragment(executable: executable)
            .trimmingCharacters(in: .newlines)
        let digest = InstallerDigest.data(Data(fragment.utf8))
        let existing = FileManager.default.fileExists(atPath: configURL.path)
            ? (try String(contentsOf: configURL, encoding: .utf8))
            : ""

        var shouldWriteConfig = true
        if let currentFragment = McpTomlConfig.ownedFragment(in: existing) {
            let current = InstallerDigest.data(Data(currentFragment.utf8))
            let previouslyOwned = previousFiles.contains { $0.path == mcpPath && $0.sha256 == current }
            if current != digest, !previouslyOwned {
                preserved.append(configURL.path)
                if let previous = previousFiles.first(where: { $0.path == mcpPath }) {
                    ownedFiles.append(previous)
                }
                shouldWriteConfig = false
            }
        } else if McpTomlConfig.hasChorusTable(existing), !McpTomlConfig.hasMarkers(existing) {
            // Foreign unmanaged table — do not clobber.
            preserved.append(configURL.path)
            if let previous = previousFiles.first(where: { $0.path == mcpPath }) {
                ownedFiles.append(previous)
            }
            shouldWriteConfig = false
        }

        if shouldWriteConfig {
            try backupIfNeeded(configURL)
            let merged = McpTomlConfig.upsert(existing: existing, fragment: fragment)
            try AtomicInstallerFile.write(Data(merged.utf8), to: configURL, permissions: 0o600)
            ownedFiles.append(OwnedInstalledFile(host: host, path: mcpPath, sha256: digest))
        }
    }

    private func uninstallTomlMcp(
        host: HostSource,
        manifest: InstallManifest,
        preserved: inout [String]
    ) throws {
        let configURL = mcpTomlConfigURL(for: host)
        let mcpPath = Self.mcpOwnershipPath(for: host)
        if FileManager.default.fileExists(atPath: configURL.path),
           let owned = manifest.files.first(where: { $0.host == host && $0.path == mcpPath }) {
            let existing = try String(contentsOf: configURL, encoding: .utf8)
            if let currentFragment = McpTomlConfig.ownedFragment(in: existing) {
                let current = InstallerDigest.data(Data(currentFragment.utf8))
                if current == owned.sha256 {
                    let cleaned = McpTomlConfig.removeOwned(existing)
                    try AtomicInstallerFile.write(Data(cleaned.utf8), to: configURL, permissions: 0o600)
                } else {
                    preserved.append(configURL.path)
                }
            }
            // Markers gone: drop ownership silently (nothing to remove).
        }
    }

    // MARK: - Grok (TOML MCP + speak skill)

    private func installGrokHost(
        previousFiles: [OwnedInstalledFile],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        try installTomlMcp(
            host: .grok,
            previousFiles: previousFiles,
            ownedFiles: &ownedFiles,
            preserved: &preserved
        )

        // chorus-speak skill (digest ownership, same as setup skills).
        let skillText = EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable)
        let destination = skillsDirectory(for: .grok).appending(path: "chorus-speak/SKILL.md")
        try installSkillFile(
            text: skillText,
            destination: destination,
            host: .grok,
            previousFiles: previousFiles,
            ownedFiles: &ownedFiles,
            preserved: &preserved
        )
    }

    private func uninstallGrokHost(
        manifest: InstallManifest,
        preserved: inout [String]
    ) throws {
        try uninstallTomlMcp(host: .grok, manifest: manifest, preserved: &preserved)

        for owned in manifest.files where owned.host == .grok {
            if owned.path.hasPrefix("mcp:") { continue }
            try removeOwnedFile(owned, preserved: &preserved)
        }
    }

    // MARK: - Shared helpers

    private func installSkills(
        for host: HostSource,
        previousFiles: [OwnedInstalledFile],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        let templates = EmbeddedTemplates.skills(executable: executable)
        for name in EmbeddedTemplates.skillNames {
            guard let text = templates[name] else { continue }
            let destination = skillsDirectory(for: host)
                .appending(path: "chorus-\(name)/SKILL.md")
            try installSkillFile(
                text: text,
                destination: destination,
                host: host,
                previousFiles: previousFiles,
                ownedFiles: &ownedFiles,
                preserved: &preserved
            )
        }
    }

    private func installSkillFile(
        text: String,
        destination: URL,
        host: HostSource,
        previousFiles: [OwnedInstalledFile],
        ownedFiles: inout [OwnedInstalledFile],
        preserved: inout [String]
    ) throws {
        let data = Data(text.utf8)
        let digest = InstallerDigest.data(data)
        if FileManager.default.fileExists(atPath: destination.path) {
            let current = InstallerDigest.data(try Data(contentsOf: destination))
            let previouslyOwned = previousFiles.contains { $0.path == destination.path && $0.sha256 == current }
            if current != digest, !previouslyOwned {
                preserved.append(destination.path)
                if let previous = previousFiles.first(where: { $0.path == destination.path }) {
                    ownedFiles.append(previous)
                }
                return
            }
        }
        try AtomicInstallerFile.write(data, to: destination, permissions: 0o600)
        ownedFiles.append(OwnedInstalledFile(host: host, path: destination.path, sha256: digest))
    }

    private func removeOwnedFile(_ owned: OwnedInstalledFile, preserved: inout [String]) throws {
        guard FileManager.default.fileExists(atPath: owned.path) else { return }
        let current = InstallerDigest.data(try Data(contentsOf: URL(fileURLWithPath: owned.path)))
        if current == owned.sha256 {
            try FileManager.default.removeItem(atPath: owned.path)
        } else {
            preserved.append(owned.path)
        }
    }

    /// Hook / settings JSON path (Codex hooks, Claude settings). Grok uses TOML only.
    private func settingsURL(for host: HostSource) -> URL {
        switch host {
        case .codex: home.appending(path: ".codex/hooks.json")
        case .claude: home.appending(path: ".claude/settings.json")
        case .grok: home.appending(path: ".grok/config.toml")
        }
    }

    /// Codex / Grok native MCP config path (TOML).
    private func mcpTomlConfigURL(for host: HostSource) -> URL {
        switch host {
        case .codex: home.appending(path: ".codex/config.toml")
        case .grok: home.appending(path: ".grok/config.toml")
        case .claude: home.appending(path: ".claude/settings.json") // unused
        }
    }

    private func skillsDirectory(for host: HostSource) -> URL {
        switch host {
        case .codex: home.appending(path: ".agents/skills", directoryHint: .isDirectory)
        case .claude: home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        case .grok: home.appending(path: ".grok/skills", directoryHint: .isDirectory)
        }
    }

    private func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw HostInstallerError.settingsRootMustBeObject
        }
        return root
    }

    private func hooksObject(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw HostInstallerError.hooksMustBeObject }
        return hooks
    }

    private func eventEntries(_ event: HookEventName, from hooks: [String: Any]) throws -> [Any] {
        guard let value = hooks[event.rawValue] else { return [] }
        guard let entries = value as? [Any] else {
            throw HostInstallerError.eventHooksMustBeArray(event.rawValue)
        }
        return entries
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func backupIfNeeded(_ url: URL) throws {
        let backup = URL(fileURLWithPath: url.path + ".chorus-backup")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try AtomicInstallerFile.write(try Data(contentsOf: url), to: backup, permissions: 0o600)
    }

    private func writeSettings(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicInstallerFile.write(data, to: url, permissions: 0o600)
    }
}
