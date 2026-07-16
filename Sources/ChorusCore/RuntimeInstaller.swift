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
        let paths = ChorusPaths.forHome(home)
        try installExecutable(from: sourceExecutable, to: paths.executableURL)
        _ = try await modelInstaller.install(repair: repair)
        let hostResult = try HostInstaller(home: home, executable: paths.executableURL)
            .install(hosts: hosts)
        try AtomicInstallerFile.write(
            try EmbeddedTemplates.launchAgent(executable: paths.executableURL),
            to: paths.launchAgentURL,
            permissions: 0o600
        )
        try recordRuntimeOwnership(paths: paths)
        let domain = "gui/\(userID)"
        try await launchctl.run(
            arguments: ["bootout", "\(domain)/com.chorus.tts"],
            allowFailure: true
        )
        try await launchctl.run(
            arguments: ["bootstrap", domain, paths.launchAgentURL.path],
            allowFailure: false
        )
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
        for url in [paths.launchAgentURL, paths.executableURL] {
            guard let owned = manifest.runtimeFiles.first(where: { $0.path == url.path }),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let digest = InstallerDigest.data(try Data(contentsOf: url))
            if digest == owned.sha256 {
                try FileManager.default.removeItem(at: url)
            } else {
                preserved.append(url.path)
            }
        }
        manifest.runtimeFiles.removeAll { owned in
            owned.path == paths.launchAgentURL.path || owned.path == paths.executableURL.path
        }
        try manifest.save(to: paths.installManifestURL)
        return HostInstallResult(
            codexReviewRequired: false,
            preservedModifiedFiles: preserved.sorted()
        )
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
        let urls = [paths.executableURL, paths.launchAgentURL]
        manifest.runtimeFiles.removeAll { owned in urls.contains { $0.path == owned.path } }
        manifest.runtimeFiles.append(contentsOf: try urls.map { url in
            OwnedRuntimeFile(
                path: url.path,
                sha256: InstallerDigest.data(try Data(contentsOf: url))
            )
        })
        try manifest.save(to: paths.installManifestURL)
    }
}
