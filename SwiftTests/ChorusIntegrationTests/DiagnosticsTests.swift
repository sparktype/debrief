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

    @Test func statusTextUsesCliLines() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try ChorusConfiguration(mode: .night, muted: true, companionEnabled: false).save(to: paths.configURL)
        try installModelMarker(paths: paths, corrupt: true)
        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: paths.launchAgentURL)

        let text = Diagnostics(home: home, processExists: { _ in false }).statusText()
        #expect(text.contains("프로세스: 없음"))
        #expect(text.contains("음소거: 켜짐"))
        #expect(text.contains("모드: night"))
        #expect(text.contains("도우미 음성: 꺼짐"))
        #expect(text.contains("모델: \(ModelManifest.supertonic3.revision) (사용할 수 없음)"))
        #expect(text.contains("소켓: 없음"))
        #expect(text.contains("LaunchAgent: 설치됨"))
        #expect(!text.localizedCaseInsensitiveContains("menu"))
    }

    @Test func doctorParkedDaemonSuggestsRepairNotTheMenu() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("123".utf8).write(to: paths.pidURL)
        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: paths.launchAgentURL)
        try installModelMarker(paths: paths)

        let diagnostics = Diagnostics(home: home, processExists: { $0 == 123 })
        let findings = diagnostics.doctor()
        #expect(findings.contains { $0.code == "daemon.running" && $0.ok })
        let socket = findings.first { $0.code == "socket.missing" }
        #expect(socket?.ok == false)
        #expect(socket?.recovery == "debrief install --repair")
        let report = diagnostics.doctorReportText()
        #expect(!report.localizedCaseInsensitiveContains("menu"))
        #expect(!report.contains("menubar"))
    }

    @Test func doctorStoppedDaemonWithPlistSuggestsStart() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ChorusPaths.forHome(home)
        try FileManager.default.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: paths.launchAgentURL)
        try installModelMarker(paths: paths)

        let findings = Diagnostics(home: home, processExists: { _ in false }).doctor()
        let daemon = findings.first { $0.code == "daemon.missing" }
        #expect(daemon?.recovery == "debrief start")
        #expect(findings.contains { $0.code == "socket.missing" && $0.recovery == "debrief start" })
    }

    @Test func doctorUsesHostAwareCodeForUnreadableGrokToml() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grok = home.appending(path: ".grok/config.toml")
        try FileManager.default.createDirectory(at: grok.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Non-UTF-8 so settingsReadableToml fails without looking like JSON.
        try Data([0xFF, 0xFE, 0xFD]).write(to: grok)

        let findings = Diagnostics(home: home, processExists: { _ in false }).doctor()
        // MCP probe collapses unreadable host config into a single mcp.* finding.
        #expect(findings.contains { $0.code == "mcp.grok.unreadable" && !$0.ok })
        #expect(!findings.contains { $0.code == "host.grok.invalid_toml" })
        #expect(!findings.contains { $0.code == "host.grok.invalid_json" })
        let grokFinding = try #require(findings.first { $0.code == "mcp.grok.unreadable" })
        #expect(grokFinding.recovery != nil)
    }

    @Test func doctorReportsMissingClaudeMcpWhenSettingsExist() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeJSON(["mcpServers": [:]], to: home.appending(path: ".claude/settings.json"))

        let findings = Diagnostics(home: home, processExists: { _ in false }).doctor()
        #expect(findings.contains { $0.code == "mcp.claude.missing" && !$0.ok })
        let statuses = Diagnostics(home: home).hostMcpStatuses()
        #expect(statuses.contains { $0.host == .claude && $0.state == .missing })
    }

    @Test func doctorIncludesLastErrorAndProblemLines() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let diagnostics = Diagnostics(home: home)
        try diagnostics.recordError(component: "tts", code: "synthesis_or_playback", message: "합성 실패")
        let findings = diagnostics.doctor()
        #expect(findings.contains { $0.code == "last_error.synthesis_or_playback" && !$0.ok })
        let lines = diagnostics.doctorProblemLines()
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.contains("synthesis_or_playback") || $0.contains("합성") })
        let report = diagnostics.doctorReportText()
        #expect(report.contains("debrief 진단"))
        #expect(report.contains("synthesis_or_playback") || report.contains("합성"))
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
