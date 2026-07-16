import Foundation
import Testing
@testable import ChorusCore

@Suite("HostInstallerTests")
struct HostInstallerTests {
    @Test func installPreservesSettingsBacksUpAndDoesNotDuplicate() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex/hooks.json")
        let claude = home.appending(path: ".claude/settings.json")
        try writeJSON([
            "mcpServers": ["keep": ["command": "unrelated"]],
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: codex)
        try writeJSON([
            "theme": "dark",
            "hooks": ["Notification": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: claude)
        let installer = HostInstaller(home: home, executable: ChorusPaths.forHome(home).executableURL)

        let first = try installer.install(hosts: Set(HostSource.allCases))
        let second = try installer.install(hosts: Set(HostSource.allCases))

        #expect(first.codexReviewRequired)
        #expect(second.codexReviewRequired)
        #expect(FileManager.default.fileExists(atPath: codex.path + ".chorus-backup"))
        #expect(FileManager.default.fileExists(atPath: claude.path + ".chorus-backup"))
        let codexJSON = try json(at: codex)
        let claudeJSON = try json(at: claude)
        #expect((codexJSON["mcpServers"] as? [String: Any])?["keep"] != nil)
        #expect(claudeJSON["theme"] as? String == "dark")
        assertInstalledHooks(codexJSON, unrelatedEvent: "PreToolUse")
        assertInstalledHooks(claudeJSON, unrelatedEvent: "Notification")

        for source in HostSource.allCases {
            let base = source == .codex ? home.appending(path: ".agents/skills") : home.appending(path: ".claude/skills")
            for name in EmbeddedTemplates.skillNames {
                #expect(FileManager.default.fileExists(
                    atPath: base.appending(path: "chorus-\(name)/SKILL.md").path
                ))
            }
        }
    }

    @Test func uninstallRemovesOnlyUnchangedOwnedContent() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HostInstaller(home: home, executable: ChorusPaths.forHome(home).executableURL)
        try installer.install(hosts: Set(HostSource.allCases))
        let modified = home.appending(path: ".agents/skills/chorus-mode/SKILL.md")
        try Data("user edit".utf8).write(to: modified)

        let result = try installer.uninstall(hosts: Set(HostSource.allCases))

        #expect(FileManager.default.fileExists(atPath: modified.path))
        #expect(result.preservedModifiedFiles == [modified.path])
        #expect(!FileManager.default.fileExists(
            atPath: home.appending(path: ".agents/skills/chorus-setup/SKILL.md").path
        ))
        for settings in [home.appending(path: ".codex/hooks.json"), home.appending(path: ".claude/settings.json")] {
            let hooks = try #require(try json(at: settings)["hooks"] as? [String: Any])
            for event in HookEventName.allCases {
                #expect(hooks[event.rawValue] == nil)
            }
        }
    }

    @Test func malformedSettingsAreRefusedWithoutBackupOrReplacement() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appending(path: ".codex/hooks.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("[]".utf8)
        try original.write(to: settings)

        #expect(throws: HostInstallerError.settingsRootMustBeObject) {
            try HostInstaller(home: home, executable: ChorusPaths.forHome(home).executableURL)
                .install(hosts: [.codex])
        }
        #expect(try Data(contentsOf: settings) == original)
        #expect(!FileManager.default.fileExists(atPath: settings.path + ".chorus-backup"))
    }

    private func assertInstalledHooks(_ root: [String: Any], unrelatedEvent: String) {
        let hooks = root["hooks"] as? [String: Any]
        #expect(hooks?[unrelatedEvent] != nil)
        for event in HookEventName.allCases {
            #expect((hooks?[event.rawValue] as? [Any])?.count == 1)
        }
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chorus-host-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
