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

public enum RuntimeInstallerError: Error, Equatable, Sendable {
    case launchctlFailed(Int32)
    case atomicExecutableReplacementFailed
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

    /// Optional PNG used for `Chorus.app` Finder icon (`sips` + `iconutil`).
    public var applicationIconPNG: Data?

    @discardableResult
    public func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult {
        let paths = ChorusPaths.forHome(home)
        try installApplicationBundle(paths: paths)
        try removeLegacyCLISymlink(at: paths.legacyCLISymlinkURL)
        _ = try await modelInstaller.install(repair: repair)
        // Hooks invoke the app binary directly — no CLI wrapper path.
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .install(hosts: hosts)
        try AtomicInstallerFile.write(
            try EmbeddedTemplates.launchAgent(executable: paths.executableURL),
            to: paths.launchAgentURL,
            permissions: 0o600
        )
        try recordRuntimeOwnership(paths: paths)
        let domain = "gui/\(userID)"
        // Menu Quit disables the agent so KeepAlive does not relaunch; re-enable on install.
        try await launchctl.run(
            arguments: LaunchAgentControl.enableArguments(userID: userID),
            allowFailure: true
        )
        try await launchctl.run(
            arguments: ["bootout", "\(domain)/com.chorus.tts"],
            allowFailure: true
        )
        try await launchctl.run(
            arguments: ["bootstrap", domain, paths.launchAgentURL.path],
            allowFailure: false
        )
        try await migrateLegacyIfPresent(paths: paths)
        return hostResult
    }

    @discardableResult
    public func uninstall(hosts: Set<HostSource>) async throws -> HostInstallResult {
        let paths = ChorusPaths.forHome(home)
        var manifest = try InstallManifest.load(from: paths.installManifestURL)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .uninstall(hosts: hosts)
        var preserved = hostResult.preservedModifiedFiles
        try await launchctl.run(
            arguments: ["bootout", "gui/\(userID)/com.chorus.tts"],
            allowFailure: true
        )
        try removeLegacyCLISymlink(at: paths.legacyCLISymlinkURL)
        let removable = [
            paths.launchAgentURL,
            paths.executableURL,
            AppBundleInstaller.infoPlistURL(appBundle: paths.applicationBundleURL),
            AppBundleInstaller.iconURL(appBundle: paths.applicationBundleURL),
            AppBundleInstaller.menuBarIconURL(appBundle: paths.applicationBundleURL),
            AppBundleInstaller.menuBarIcon2xURL(appBundle: paths.applicationBundleURL),
        ]
        for url in removable {
            guard let owned = manifest.runtimeFiles.first(where: { $0.path == url.path }),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let digest = InstallerDigest.data(try Data(contentsOf: url))
            if digest == owned.sha256 {
                try FileManager.default.removeItem(at: url)
            } else {
                preserved.append(url.path)
            }
        }
        // Drop empty app bundle shells after owned files are removed.
        try? removeEmptyAppBundle(paths.applicationBundleURL)
        manifest.runtimeFiles.removeAll { owned in
            removable.contains { $0.path == owned.path }
                || owned.path.hasPrefix(paths.applicationBundleURL.path + "/")
        }
        try manifest.save(to: paths.installManifestURL)
        return HostInstallResult(
            codexReviewRequired: false,
            preservedModifiedFiles: preserved.sorted()
        )
    }

    private func installApplicationBundle(paths: ChorusPaths) throws {
        try AppBundleInstaller.install(
            sourceExecutable: sourceExecutable,
            appBundle: paths.applicationBundleURL,
            version: ChorusVersion.current,
            iconPNG: applicationIconPNG,
            installExecutable: installExecutable(from:to:)
        )
    }

    private func removeEmptyAppBundle(_ appBundle: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appBundle.path) else { return }
        // Remove whole app if MacOS binary is gone.
        let executable = AppBundleInstaller.executableURL(appBundle: appBundle)
        if !fileManager.fileExists(atPath: executable.path) {
            try? fileManager.removeItem(at: appBundle)
        }
    }

    private func installExecutable(from source: URL, to destination: URL) throws {
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
        var urls = [
            paths.executableURL,
            paths.launchAgentURL,
            AppBundleInstaller.infoPlistURL(appBundle: paths.applicationBundleURL),
        ]
        let icon = AppBundleInstaller.iconURL(appBundle: paths.applicationBundleURL)
        if FileManager.default.fileExists(atPath: icon.path) {
            urls.append(icon)
        }
        let menuBarIcon = AppBundleInstaller.menuBarIconURL(appBundle: paths.applicationBundleURL)
        if FileManager.default.fileExists(atPath: menuBarIcon.path) {
            urls.append(menuBarIcon)
        }
        let menuBarIcon2x = AppBundleInstaller.menuBarIcon2xURL(appBundle: paths.applicationBundleURL)
        if FileManager.default.fileExists(atPath: menuBarIcon2x.path) {
            urls.append(menuBarIcon2x)
        }
        manifest.runtimeFiles.removeAll { owned in
            urls.contains { $0.path == owned.path }
                || owned.path.hasPrefix(paths.applicationBundleURL.path + "/")
                || owned.path == paths.legacyCLISymlinkURL.path
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

    /// Removes the retired `~/.local/bin/chorus` symlink or bare binary from older installs.
    private func removeLegacyCLISymlink(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
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
