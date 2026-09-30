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

    public init(
        home: URL,
        sourceExecutable: URL,
        modelInstaller: Model,
        launchctl: Launchctl,
        userID: UInt32 = getuid()
    ) {
        self.home = home
        self.sourceExecutable = sourceExecutable
        self.modelInstaller = modelInstaller
        self.launchctl = launchctl
        self.userID = userID
    }

    @discardableResult
    public func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult {
        let paths = DebriefPaths.forHome(home)
        let previousExecutable = try? Data(contentsOf: paths.executableURL)
        try installExecutable(from: sourceExecutable, to: paths.executableURL)
        _ = try await modelInstaller.install(repair: repair)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .install(hosts: hosts)
        let launchAgentData = try EmbeddedTemplates.launchAgent(executable: paths.executableURL)
        let executableChanged = previousExecutable != (try? Data(contentsOf: paths.executableURL))
        let plistChanged = (try? Data(contentsOf: paths.launchAgentURL)) != launchAgentData
        try AtomicInstallerFile.write(
            launchAgentData,
            to: paths.launchAgentURL,
            permissions: 0o600
        )
        try recordRuntimeOwnership(paths: paths)
        // Re-bootstrapping an unchanged agent makes launchd re-register the login item with
        // Background Task Management every time; doing that repeatedly trips BTM's own
        // notification rate limit, which then makes `bootstrap` itself fail with EIO. Skip the
        // re-registration entirely when nothing that requires it changed.
        if executableChanged || plistChanged || !isAgentHealthy() {
            try await bootstrapLaunchAgent(paths: paths)
        }
        return hostResult
    }

    private func isAgentHealthy() -> Bool {
        let snapshot = Diagnostics(home: home).status()
        return snapshot.process == .running && snapshot.socketPresent
    }

    /// Enables an existing LaunchAgent. Does not write a plist or change config.json.
    public func start() async throws -> ServiceStartResult {
        let paths = DebriefPaths.forHome(home)
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
    private func bootstrapLaunchAgent(paths: DebriefPaths) async throws {
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
        let paths = DebriefPaths.forHome(home)
        var manifest = try InstallManifest.load(from: paths.installManifestURL)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .uninstall(hosts: hosts)
        var preserved = hostResult.preservedModifiedFiles
        try await disableAndBootout()
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
        manifest.runtimeFiles.removeAll { owned in
            removable.contains { $0.path == owned.path }
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
            .appending(path: ".debrief.\(UUID().uuidString).tmp")
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

    private func recordRuntimeOwnership(paths: DebriefPaths) throws {
        var manifest = try InstallManifest.load(from: paths.installManifestURL)
        let urls = [paths.executableURL, paths.launchAgentURL]
        manifest.runtimeFiles.removeAll { owned in
            urls.contains { $0.path == owned.path }
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
}
