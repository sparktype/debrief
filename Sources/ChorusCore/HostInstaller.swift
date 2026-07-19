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

public struct HostInstaller: Sendable {
    private let home: URL
    private let executable: URL
    private let manifestURL: URL

    public init(home: URL, executable: URL, manifestURL: URL? = nil) {
        self.home = home
        self.executable = executable
        self.manifestURL = manifestURL ?? ChorusPaths.forHome(home).installManifestURL
    }

    @discardableResult
    public func install(hosts: Set<HostSource>) throws -> HostInstallResult {
        var manifest = try InstallManifest.load(from: manifestURL)
        var preserved: [String] = []

        for host in hosts.sorted(by: { $0.rawValue < $1.rawValue }) {
            // Task 4: Grok TOML MCP install — skip until implemented.
            if host == .grok { continue }

            let settingsURL = settingsURL(for: host)
            var root = try readSettings(at: settingsURL)
            let previousFiles = manifest.files.filter { $0.host == host }
            var ownedHooks: [OwnedHook] = []
            var hooks = try hooksObject(from: root)

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
            try backupIfNeeded(settingsURL)
            try writeSettings(root, to: settingsURL)

            var ownedFiles: [OwnedInstalledFile] = []
            let templates = EmbeddedTemplates.skills(executable: executable)
            for name in EmbeddedTemplates.skillNames {
                guard let text = templates[name] else { continue }
                let destination = skillsDirectory(for: host)
                    .appending(path: "chorus-\(name)/SKILL.md")
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
                        continue
                    }
                }
                try AtomicInstallerFile.write(data, to: destination, permissions: 0o600)
                ownedFiles.append(OwnedInstalledFile(host: host, path: destination.path, sha256: digest))
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
            // Task 4: Grok TOML MCP uninstall — skip until implemented.
            if host == .grok { continue }

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
                try writeSettings(root, to: settingsURL)
            }

            for owned in manifest.files where owned.host == host {
                guard FileManager.default.fileExists(atPath: owned.path) else { continue }
                let current = InstallerDigest.data(try Data(contentsOf: URL(fileURLWithPath: owned.path)))
                if current == owned.sha256 {
                    try FileManager.default.removeItem(atPath: owned.path)
                } else {
                    preserved.append(owned.path)
                }
            }
            manifest.hooks.removeAll { $0.host == host }
            manifest.files.removeAll { $0.host == host }
        }
        try manifest.save(to: manifestURL)
        return HostInstallResult(codexReviewRequired: false, preservedModifiedFiles: preserved.sorted())
    }

    private func settingsURL(for host: HostSource) -> URL {
        switch host {
        case .codex: home.appending(path: ".codex/hooks.json")
        case .claude: home.appending(path: ".claude/settings.json")
        // Task 4: real Grok TOML path used by install; stub keeps switch exhaustive.
        case .grok: home.appending(path: ".grok/config.toml")
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
