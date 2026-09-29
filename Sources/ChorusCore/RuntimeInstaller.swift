import Darwin
import Foundation

public protocol RuntimeModelInstalling: Sendable {
    func install(repair: Bool) async throws -> InstalledModel
}

extension ModelInstaller: RuntimeModelInstalling {}

public protocol LaunchctlRunning: Sendable {
    func run(arguments: [String], allowFailure: Bool) async throws
}

public struct ProcessLaunchctlRunner: LaunchctlRunning {
    public init() {}

    public func run(arguments: [String], allowFailure: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw RuntimeInstallerError.launchctlFailed(process.terminationStatus)
        }
    }
}

public enum ServiceStartResult: Equatable, Sendable {
    case started
    case alreadyRunning
}

public enum RuntimeInstallerError: Error, Equatable, Sendable, CustomStringConvertible {
    case launchctlFailed(Int32)
    case atomicExecutableReplacementFailed
    case executablePathIsDirectory
    case launchAgentMissing

    public var description: String {
        switch self {
        case let .launchctlFailed(status):
            return "launchctl failed (\(status))"
        case .atomicExecutableReplacementFailed:
            return "실행 파일을 바꾸지 못했습니다."
        case .executablePathIsDirectory:
            return CliMessages.executablePathIsDirectory
        case .launchAgentMissing:
            return CliMessages.launchAgentMissing
        }
    }
}

public struct RuntimeInstaller<Model: RuntimeModelInstalling, Launchctl: LaunchctlRunning>: Sendable {
    private let home: URL
    private let sourceExecutable: URL
    private let modelInstaller: Model
    private let launchctl: Launchctl
    private let userID: UInt32
    private let healthCheck: @Sendable (ChorusPaths) async -> Bool

    public init(
        home: URL,
        sourceExecutable: URL,
        modelInstaller: Model,
        launchctl: Launchctl,
        userID: UInt32 = getuid(),
        healthCheck: @escaping @Sendable (ChorusPaths) async -> Bool = RuntimeInstaller.liveHealthCheck
    ) {
        self.home = home
        self.sourceExecutable = sourceExecutable
        self.modelInstaller = modelInstaller
        self.launchctl = launchctl
        self.userID = userID
        self.healthCheck = healthCheck
    }

    @discardableResult
    public func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult {
        let paths = ChorusPaths.forHome(home)
        await retirePreviousLaunchAgents()
        try installExecutable(from: sourceExecutable, to: paths.executableURL)
        removeRetiredCLIIfFile(at: home.appending(path: ".local/bin/chorus"))
        _ = try await modelInstaller.install(repair: repair)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .install(hosts: hosts)
        try AtomicInstallerFile.write(
            try EmbeddedTemplates.launchAgent(executable: paths.executableURL),
            to: paths.launchAgentURL,
            permissions: 0o600
        )
        try recordRuntimeOwnership(paths: paths)
        try await bootstrapLaunchAgent(paths: paths)
        removeOwnedApplicationBundles()
        // Legacy migration must not fail a successful install/bootstrap.
        try? await migrateLegacyIfPresent(paths: paths)
        return hostResult
    }

    /// Enables an existing LaunchAgent. Does not write a plist or change config.json.
    public func start() async throws -> ServiceStartResult {
        let paths = ChorusPaths.forHome(home)
        guard FileManager.default.fileExists(atPath: paths.launchAgentURL.path) else {
            throw RuntimeInstallerError.launchAgentMissing
        }
        if Diagnostics(home: home).status().process == .running {
            return .alreadyRunning
        }
        try await bootstrapLaunchAgent(paths: paths)
        return .started
    }

    /// Disables and bootouts the agent. Keeps the plist and the executable.
    public func stop() async throws {
        try await disableAndBootout()
    }

    /// Enables, boots out any prior job, then bootstraps. Retries once on bootstrap I/O races.
    private func bootstrapLaunchAgent(paths: ChorusPaths) async throws {
        let domain = "gui/\(userID)"
        let service = "\(domain)/com.debrief.tts"
        // Menu Quit disables the agent so KeepAlive does not relaunch; re-enable on install.
        try await launchctl.run(
            arguments: LaunchAgentControl.enableArguments(userID: userID),
            allowFailure: true
        )
        try await launchctl.run(
            arguments: ["bootout", service],
            allowFailure: true
        )
        do {
            try await launchctl.run(
                arguments: ["bootstrap", domain, paths.launchAgentURL.path],
                allowFailure: false
            )
        } catch {
            // Concurrent replace of a live agent can return EIO once; bootout again and retry.
            try await launchctl.run(arguments: ["bootout", service], allowFailure: true)
            try? await Task.sleep(for: .milliseconds(300))
            try await launchctl.run(
                arguments: LaunchAgentControl.enableArguments(userID: userID),
                allowFailure: true
            )
            try await launchctl.run(
                arguments: ["bootstrap", domain, paths.launchAgentURL.path],
                allowFailure: false
            )
        }
    }

    @discardableResult
    public func uninstall(hosts: Set<HostSource>) async throws -> HostInstallResult {
        let paths = ChorusPaths.forHome(home)
        var manifest = try InstallManifest.load(from: paths.installManifestURL)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .uninstall(hosts: hosts)
        var preserved = hostResult.preservedModifiedFiles
        try await disableAndBootout()
        removeRetiredCLIIfFile(at: home.appending(path: ".local/bin/chorus"))
        let removable = [paths.launchAgentURL, paths.executableURL]
        for url in removable {
            var isDirectory: ObjCBool = false
            guard let owned = manifest.runtimeFiles.first(where: { $0.path == url.path }),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let digest = InstallerDigest.data(try Data(contentsOf: url))
            if digest == owned.sha256 {
                try FileManager.default.removeItem(at: url)
            } else {
                preserved.append(url.path)
            }
        }
        removeOwnedApplicationBundles()
        manifest.runtimeFiles.removeAll { owned in
            removable.contains { $0.path == owned.path } || Self.isRetiredAppPath(owned.path)
        }
        try manifest.save(to: paths.installManifestURL)
        return HostInstallResult(
            codexReviewRequired: false,
            preservedModifiedFiles: preserved.sorted()
        )
    }

    private func disableAndBootout() async throws {
        try await launchctl.run(
            arguments: LaunchAgentControl.disableArguments(userID: userID),
            allowFailure: true
        )
        try await launchctl.run(
            arguments: LaunchAgentControl.bootoutArguments(userID: userID),
            allowFailure: true
        )
    }

    private func installExecutable(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw RuntimeInstallerError.executablePathIsDirectory
        }
        if source.standardizedFileURL == destination.standardizedFileURL {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".chorus.\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: destination.path) {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                try? fileManager.removeItem(at: temporary)
                throw RuntimeInstallerError.atomicExecutableReplacementFailed
            }
            try fileManager.removeItem(at: temporary)
        } else {
            guard rename(temporary.path, destination.path) == 0 else {
                try? fileManager.removeItem(at: temporary)
                throw RuntimeInstallerError.atomicExecutableReplacementFailed
            }
        }
    }

    private func recordRuntimeOwnership(paths: ChorusPaths) throws {
        var manifest = try InstallManifest.load(from: paths.installManifestURL)
        let urls = [paths.executableURL, paths.launchAgentURL]
        manifest.runtimeFiles.removeAll { owned in
            urls.contains { $0.path == owned.path } || Self.isRetiredAppPath(owned.path)
        }
        for url in urls {
            manifest.runtimeFiles.append(
                OwnedRuntimeFile(
                    path: url.path,
                    sha256: InstallerDigest.data(try Data(contentsOf: url))
                )
            )
        }
        try manifest.save(to: paths.installManifestURL)
    }

    /// Stops earlier agents and removes their plists. App bundles stay until bootstrap succeeds.
    private func retirePreviousLaunchAgents() async {
        for label in ["com.chorus.tts", "com.prompt-recap.tts"] {
            let previousPlist = home.appending(path: "Library/LaunchAgents/\(label).plist")
            guard FileManager.default.fileExists(atPath: previousPlist.path) else { continue }
            try? await launchctl.run(
                arguments: ["bootout", "gui/\(userID)/\(label)"],
                allowFailure: true
            )
            try? FileManager.default.removeItem(at: previousPlist)
        }
    }

    /// Deletes a leftover app only when its bundle id matches, and only at the fixed paths.
    private func removeOwnedApplicationBundles() {
        for bundle in ChorusPaths.removableApplicationBundles(home: home) {
            guard bundleIdentifier(at: bundle.url) == bundle.bundleIdentifier else { continue }
            try? FileManager.default.removeItem(at: bundle.url)
        }
    }

    private func bundleIdentifier(at app: URL) -> String? {
        let infoURL = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Removes the retired `~/.local/bin/chorus` file. A directory is left in place.
    private func removeRetiredCLIIfFile(at url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isRetiredAppPath(_ path: String) -> Bool {
        path.contains("/debrief.app/")
            || path.contains("/Chorus.app/")
            || path.contains("/prompt-recap.app/")
    }

    private func migrateLegacyIfPresent(paths: ChorusPaths) async throws {
        let legacyRoot = home.appending(path: ".local/share/chorus", directoryHint: .isDirectory)
        let configURL = legacyRoot.appending(path: "config.json")
        let voiceMapURL = legacyRoot.appending(path: "runtime/current/voice-map.json")
        let legacyPlists = LegacyMigration.knownLaunchAgentLabels.map {
            home.appending(path: "Library/LaunchAgents/\($0).plist")
        }
        let hasLegacy = FileManager.default.fileExists(atPath: configURL.path)
            || FileManager.default.fileExists(atPath: voiceMapURL.path)
            || legacyPlists.contains { FileManager.default.fileExists(atPath: $0.path) }
        guard hasLegacy else { return }
        let source = LegacyMigrationSource(
            configuration: try? Data(contentsOf: configURL),
            voiceMap: try? Data(contentsOf: voiceMapURL)
        )
        let plan = try LegacyMigration.plan(from: source)
        let healthy = await healthCheck(paths)
        try await LegacyMigration.apply(
            plan,
            home: home,
            afterHealthCheck: healthy,
            runner: RuntimeLegacyServiceRunner(launchctl: launchctl, userID: userID)
        )
    }

    public static func liveHealthCheck(paths: ChorusPaths) async -> Bool {
        for _ in 0..<25 {
            let snapshot = Diagnostics(home: paths.home).status()
            if snapshot.process == .running,
               snapshot.socketPresent,
               snapshot.modelValid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}

private struct RuntimeLegacyServiceRunner<Launchctl: LaunchctlRunning>: LegacyServiceRunning {
    let launchctl: Launchctl
    let userID: UInt32

    func unload(label: String) async throws {
        try await launchctl.run(
            arguments: ["bootout", "gui/\(userID)/\(label)"],
            allowFailure: true
        )
    }
}
