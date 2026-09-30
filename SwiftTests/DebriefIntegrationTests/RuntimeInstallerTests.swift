import Foundation
import Testing
@testable import DebriefCore

@Suite("RuntimeInstallerTests")
struct RuntimeInstallerTests {
    @Test func installCopiesBinaryBeforeModelAndBootstrapsIdempotently() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appending(path: "build/debrief")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: source)
        let paths = DebriefPaths.forHome(home)
        let events = EventLog()
        let model = FakeRuntimeModelInstaller(
            events: events,
            directory: home.appending(path: "model"),
            installedExecutable: paths.executableURL
        )
        let launchctl = FakeLaunchctlRunner(events: events)
        let installer = RuntimeInstaller(
            home: home,
            sourceExecutable: source,
            modelInstaller: model,
            launchctl: launchctl,
            userID: 501
        )

        try await installer.install(hosts: [], repair: true)
        try await installer.install(hosts: [], repair: true)

        let installed = paths.executableURL
        #expect(installed.path.hasSuffix("/.local/bin/debrief"))
        #expect(try Data(contentsOf: installed) == Data("binary".utf8))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o755)
        let recorded = await events.values
        #expect(recorded == [
            "model:true", "enable", "bootout", "bootstrap",
            "model:true", "enable", "bootout", "bootstrap",
        ])
        #expect(!recorded.contains("model-before-binary"))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.launchAgentURL), format: nil
        ) as? [String: Any]
        #expect(plist?["ProgramArguments"] as? [String] == [installed.path, "daemon"])
        #expect(plist?["AssociatedBundleIdentifiers"] == nil)
        let manifest = try InstallManifest.load(from: paths.installManifestURL)
        #expect(manifest.runtimeFiles.contains { $0.path == installed.path })
        #expect(!manifest.runtimeFiles.contains { $0.path.contains(".app") })
    }

    @Test func uninstallBootsOutBeforeRemovingExecutable() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: paths.executableURL)
        let manifest = InstallManifest(runtimeFiles: [
            OwnedRuntimeFile(
                path: paths.executableURL.path,
                sha256: InstallerDigest.data(Data("binary".utf8))
            ),
        ])
        try manifest.save(to: paths.installManifestURL)
        let events = EventLog()
        let launchctl = FakeLaunchctlRunner(events: events, executableToObserve: paths.executableURL)
        let installer = RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: FakeRuntimeModelInstaller(events: events, directory: home),
            launchctl: launchctl,
            userID: 501
        )

        try await installer.uninstall(hosts: [])

        #expect(await events.values == ["disable", "bootout:binary-present"])
        #expect(!FileManager.default.fileExists(atPath: paths.executableURL.path))
    }

    @Test func uninstallKeepsExecutableWhenDigestDiffers() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-binary".utf8).write(to: paths.executableURL)
        let manifest = InstallManifest(runtimeFiles: [
            OwnedRuntimeFile(path: paths.executableURL.path, sha256: String(repeating: "0", count: 64)),
        ])
        try manifest.save(to: paths.installManifestURL)

        let result = try await RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: FakeRuntimeModelInstaller(events: EventLog(), directory: home),
            launchctl: FakeLaunchctlRunner(events: EventLog()),
            userID: 501
        ).uninstall(hosts: [])

        #expect(try Data(contentsOf: paths.executableURL) == Data("user-binary".utf8))
        #expect(result.preservedModifiedFiles == [paths.executableURL.path])
    }

    @Test func uninstallPreservesModifiedLaunchAgent() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DebriefPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user modified plist".utf8).write(to: paths.launchAgentURL)
        let manifest = InstallManifest(runtimeFiles: [
            OwnedRuntimeFile(path: paths.launchAgentURL.path, sha256: String(repeating: "0", count: 64)),
        ])
        try manifest.save(to: paths.installManifestURL)

        let result = try await RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: FakeRuntimeModelInstaller(events: EventLog(), directory: home),
            launchctl: FakeLaunchctlRunner(events: EventLog()),
            userID: 501
        ).uninstall(hosts: [])

        #expect(try Data(contentsOf: paths.launchAgentURL) == Data("user modified plist".utf8))
        #expect(result.preservedModifiedFiles == [paths.launchAgentURL.path])
    }

    @Test func installRefusesAnExecutableDirectory() async throws {
        let blocked = temporaryHome()
        defer { try? FileManager.default.removeItem(at: blocked) }
        let destination = DebriefPaths.forHome(blocked).executableURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appending(path: "child"))
        let blockedSource = blocked.appending(path: "build/debrief")
        try FileManager.default.createDirectory(at: blockedSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: blockedSource)
        let blockedInstaller = RuntimeInstaller(
            home: blocked,
            sourceExecutable: blockedSource,
            modelInstaller: FakeRuntimeModelInstaller(events: EventLog(), directory: blocked),
            launchctl: FakeLaunchctlRunner(events: EventLog()),
            userID: 501
        )
        await #expect(throws: RuntimeInstallerError.executablePathIsDirectory) {
            try await blockedInstaller.install(hosts: [], repair: true)
        }
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "child").path))
        #expect(
            String(describing: RuntimeInstallerError.executablePathIsDirectory)
                == CliMessages.executablePathIsDirectory
        )
    }

    @Test func failedBootstrapThrows() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appending(path: "build/debrief")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: source)
        let installer = RuntimeInstaller(
            home: home,
            sourceExecutable: source,
            modelInstaller: FakeRuntimeModelInstaller(events: EventLog(), directory: home),
            launchctl: FakeLaunchctlRunner(events: EventLog(), failBootstrap: true),
            userID: 501
        )
        await #expect(throws: RuntimeInstallerError.self) {
            try await installer.install(hosts: [], repair: true)
        }
    }

    @Test func startRefusesMissingPlistAndARunningProcess() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DebriefPaths.forHome(home)
        try DebriefConfiguration(mode: .focus, muted: false).save(to: paths.configURL)
        let configBefore = try Data(contentsOf: paths.configURL)
        let installer = RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: FakeRuntimeModelInstaller(events: EventLog(), directory: home),
            launchctl: FakeLaunchctlRunner(events: EventLog()),
            userID: 501
        )
        await #expect(throws: RuntimeInstallerError.launchAgentMissing) {
            try await installer.start()
        }
        #expect(try Data(contentsOf: paths.configURL) == configBefore)

        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: paths.launchAgentURL)
        try FileManager.default.createDirectory(at: paths.pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: paths.pidURL)
        let events = EventLog()
        let running = RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: FakeRuntimeModelInstaller(events: events, directory: home),
            launchctl: FakeLaunchctlRunner(events: events),
            userID: 501
        )
        #expect(try await running.start() == .alreadyRunning)
        #expect(await events.values.isEmpty)
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "debrief-runtime-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct FakeRuntimeModelInstaller: RuntimeModelInstalling {
    let events: EventLog
    let directory: URL
    var installedExecutable: URL?

    func install(repair: Bool) async throws -> InstalledModel {
        if let installedExecutable, !FileManager.default.fileExists(atPath: installedExecutable.path) {
            await events.append("model-before-binary")
        }
        await events.append("model:\(repair)")
        return InstalledModel(revision: String(repeating: "a", count: 40), directory: directory)
    }
}

private struct FakeLaunchctlRunner: LaunchctlRunning {
    let events: EventLog
    var executableToObserve: URL?
    var failBootstrap = false

    init(events: EventLog, executableToObserve: URL? = nil, failBootstrap: Bool = false) {
        self.events = events
        self.executableToObserve = executableToObserve
        self.failBootstrap = failBootstrap
    }

    func run(arguments: [String], allowFailure: Bool) async throws {
        if arguments.first == "bootout" {
            let suffix = executableToObserve.map {
                FileManager.default.fileExists(atPath: $0.path) ? ":binary-present" : ":binary-missing"
            } ?? ""
            await events.append("bootout\(suffix)")
        } else if arguments.first == "bootstrap" {
            await events.append("bootstrap")
            if failBootstrap {
                throw RuntimeInstallerError.launchctlFailed(1)
            }
        } else if arguments.first == "enable" {
            await events.append("enable")
        } else if arguments.first == "disable" {
            await events.append("disable")
        }
    }
}
