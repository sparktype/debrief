import Foundation
import Testing
@testable import ChorusCore

@Suite("RuntimeInstallerTests")
struct RuntimeInstallerTests {
    @Test func installCopiesBinaryBeforeModelAndBootstrapsIdempotently() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appending(path: "build/chorus")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: source)
        let events = EventLog()
        let model = FakeRuntimeModelInstaller(events: events, directory: home.appending(path: "model"))
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

        let paths = ChorusPaths.forHome(home)
        let installed = paths.executableURL
        #expect(installed.path.hasSuffix("/Applications/Chorus.app/Contents/MacOS/chorus"))
        #expect(try Data(contentsOf: installed) == Data("binary".utf8))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o755)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.cliSymlinkURL.path) == installed.path)
        #expect(FileManager.default.fileExists(atPath: paths.applicationBundleURL.path))
        let recorded = await events.values
        #expect(recorded == [
            "model:true", "enable", "bootout", "bootstrap",
            "model:true", "enable", "bootout", "bootstrap",
        ])
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.launchAgentURL), format: nil
        ) as? [String: Any]
        #expect(plist?["ProgramArguments"] as? [String] == [installed.path, "menubar"])
    }

    @Test func uninstallBootsOutBeforeRemovingExecutable() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
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

        #expect(await events.values == ["bootout:binary-present"])
        #expect(!FileManager.default.fileExists(atPath: paths.executableURL.path))
    }

    @Test func uninstallPreservesModifiedLaunchAgent() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
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

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chorus-runtime-tests-\(UUID().uuidString)")
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

    func install(repair: Bool) async throws -> InstalledModel {
        await events.append("model:\(repair)")
        return InstalledModel(revision: String(repeating: "a", count: 40), directory: directory)
    }
}

private struct FakeLaunchctlRunner: LaunchctlRunning {
    let events: EventLog
    var executableToObserve: URL?

    init(events: EventLog, executableToObserve: URL? = nil) {
        self.events = events
        self.executableToObserve = executableToObserve
    }

    func run(arguments: [String], allowFailure: Bool) async throws {
        if arguments.first == "bootout" {
            let suffix = executableToObserve.map {
                FileManager.default.fileExists(atPath: $0.path) ? ":binary-present" : ":binary-missing"
            } ?? ""
            await events.append("bootout\(suffix)")
        } else if arguments.first == "bootstrap" {
            await events.append("bootstrap")
        } else if arguments.first == "enable" {
            await events.append("enable")
        } else if arguments.first == "disable" {
            await events.append("disable")
        }
    }
}
