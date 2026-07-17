import Foundation
import Testing
@testable import ChorusCore

@Suite("DiagnosticsTests")
struct DiagnosticsTests {
    @Test func statusReportsOnlyCurrentStateForHealthyInstallation() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try ChorusConfiguration(mode: .focus, muted: false).save(to: paths.configURL)
        try FileManager.default.createDirectory(at: paths.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.socketURL)
        try Data("123".utf8).write(to: paths.pidURL)
        try installModelMarker(paths: paths)
        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: paths.launchAgentURL)
        try InstallManifest(
            hooks: [OwnedHook(host: .codex, event: .stop, sha256: String(repeating: "a", count: 64))],
            files: [OwnedInstalledFile(host: .codex, path: "/missing", sha256: String(repeating: "b", count: 64))]
        ).save(to: paths.installManifestURL)
        try writeJSON([:], to: home.appending(path: ".codex/hooks.json"))
        try writeJSON([:], to: home.appending(path: ".claude/settings.json"))

        let status = Diagnostics(home: home, processExists: { $0 == 123 }).status()

        #expect(status.mode == .focus)
        #expect(status.process == .running)
        #expect(status.socketPresent)
        #expect(status.modelRevision == ModelManifest.supertonic3.revision)
        #expect(status.modelValid)
        #expect(status.ownedHookCount == 1)
        #expect(status.ownedSkillCount == 1)
        let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        for forbidden in ["history", "counter", "requestText", "metrics", "transcript", "spoken"] {
            #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test func doctorFindsStaleProcessMissingModelInvalidMarkerAndUnreadableHost() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("999".utf8).write(to: paths.pidURL)
        try writeJSON([], to: home.appending(path: ".codex/hooks.json"))
        var findings = Diagnostics(home: home, processExists: { _ in false }).doctor()
        #expect(findings.contains { $0.code == "daemon.stale_pid" && !$0.ok })
        #expect(findings.contains { $0.code == "model.missing" && !$0.ok })
        #expect(findings.contains { $0.code == "host.codex.invalid_json" && !$0.ok })

        try installModelMarker(paths: paths, corrupt: true)
        findings = Diagnostics(home: home, processExists: { _ in false }).doctor()
        #expect(findings.contains { $0.code == "model.invalid_marker" && !$0.ok })
    }

    @Test func doctorSocketMissingWhileProcessRunningSuggestsStartNotRepair() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("123".utf8).write(to: paths.pidURL)
        // No socket — intentional menu Stop while host still alive.
        try installModelMarker(paths: paths)

        let findings = Diagnostics(home: home, processExists: { $0 == 123 }).doctor()
        #expect(findings.contains { $0.code == "daemon.running" && $0.ok })
        let socket = findings.first { $0.code == "socket.missing" }
        #expect(socket != nil)
        #expect(socket?.ok == false)
        #expect(socket?.recovery?.contains("Start service") == true)
        #expect(socket?.recovery?.contains("install --repair") != true)
    }

    @Test func lastErrorAtomicallyReplacesAndBoundsNonContentMessage() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let diagnostics = Diagnostics(home: home)
        try diagnostics.recordError(component: "model", code: "download", message: String(repeating: "x", count: 400))
        let first = try Data(contentsOf: ChorusPaths.forHome(home).lastErrorURL)
        try diagnostics.recordError(component: "daemon", code: "socket", message: "socket unavailable\nretry")
        let second = try Data(contentsOf: ChorusPaths.forHome(home).lastErrorURL)
        #expect(first != second)
        let value = try JSONDecoder().decode(CurrentError.self, from: second)
        #expect(value.component == "daemon")
        #expect(value.message == "socket unavailable retry")
        #expect(value.message.count <= CurrentError.maximumMessageLength)
        #expect(diagnostics.currentError()?.code == "socket")
        try diagnostics.clearCurrentError()
        #expect(diagnostics.currentError() == nil)
        #expect(!FileManager.default.fileExists(atPath: ChorusPaths.forHome(home).lastErrorURL.path))
    }

    private func installModelMarker(paths: ChorusPaths, corrupt: Bool = false) throws {
        let manifest = ModelManifest.supertonic3
        let directory = paths.modelsDirectory.appending(path: "supertonic-3/\(manifest.revision)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = corrupt ? Data("{}".utf8) : try JSONEncoder().encode(manifest)
        try marker.write(to: directory.appending(path: ".validated.json"))
        try writeJSON(
            ["revision": manifest.revision, "relativePath": manifest.revision],
            to: paths.modelsDirectory.appending(path: "supertonic-3/current.json")
        )
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chorus-diagnostics-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
