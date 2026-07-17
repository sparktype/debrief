import Foundation
import Testing
@testable import ChorusCore

@Suite("ConfigurationTests")
struct ConfigurationTests {
    @Test func pathsStayUnderTheProvidedHome() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = ChorusPaths.forHome(home)

        #expect(paths.dataDirectory.path == "/Users/example/Library/Application Support/Chorus")
        #expect(paths.cacheDirectory.path == "/Users/example/Library/Caches/Chorus")
        #expect(paths.configURL.path == "/Users/example/Library/Application Support/Chorus/config.json")
        #expect(paths.socketURL.path == "/Users/example/Library/Caches/Chorus/chorus.sock")
        #expect(paths.launchAgentURL.path == "/Users/example/Library/LaunchAgents/com.chorus.tts.plist")
        #expect(paths.pidURL.path == "/Users/example/Library/Caches/Chorus/daemon.pid")
        #expect(paths.lastErrorURL.path == "/Users/example/Library/Caches/Chorus/last-error.json")
        #expect(paths.legacyCLISymlinkURL.path == "/Users/example/.local/bin/chorus")
        // Fake homes always use home/Applications (not real /Applications).
        #expect(paths.applicationBundleURL.path == "/Users/example/Applications/Chorus.app")
        #expect(paths.executableURL.path == "/Users/example/Applications/Chorus.app/Contents/MacOS/chorus")
    }

    @Test func missingAndCorruptFilesRecoverToDefaults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        #expect(ChorusConfiguration.load(from: url) == .default)
        try Data("not-json".utf8).write(to: url)
        #expect(ChorusConfiguration.load(from: url) == .default)
    }

    @Test func saveAtomicallyReplacesConfigurationWithUserOnlyPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/config.json")

        try ChorusConfiguration(mode: .normal, muted: false).save(to: url)
        try ChorusConfiguration(mode: .night, muted: true).save(to: url)

        #expect(ChorusConfiguration.load(from: url).mode == .night)
        #expect(ChorusConfiguration.load(from: url).muted)
        let fileMode = try permissions(at: url)
        let directoryMode = try permissions(at: url.deletingLastPathComponent())
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(siblings.map(\.lastPathComponent) == ["config.json"])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "chorus-config-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
