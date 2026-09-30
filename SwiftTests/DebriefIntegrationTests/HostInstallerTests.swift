import Foundation
import Testing
@testable import DebriefCore

@Suite("HostInstallerTests")
struct HostInstallerTests {
    @Test func installPreservesSettingsBacksUpAndDoesNotDuplicate() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex/hooks.json")
        let codexConfig = home.appending(path: ".codex/config.toml")
        let claude = home.appending(path: ".claude/settings.json")
        try writeJSON([
            "mcpServers": ["keep": ["command": "unrelated"]],
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: codex)
        try writeJSON([
            "theme": "dark",
            "hooks": ["Notification": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: claude)
        let installer = HostInstaller(home: home, executable: DebriefPaths.forHome(home).executableURL)

        let first = try installer.install(hosts: Set(HostSource.allCases))
        let second = try installer.install(hosts: Set(HostSource.allCases))

        #expect(first.codexReviewRequired)
        #expect(second.codexReviewRequired)
        #expect(FileManager.default.fileExists(atPath: codex.path + ".debrief-backup"))
        #expect(FileManager.default.fileExists(atPath: claude.path + ".debrief-backup"))
        let codexJSON = try json(at: codex)
        let claudeJSON = try json(at: claude)
        // Codex MCP lives in config.toml — hooks.json must not gain mcpServers.debrief.
        #expect((codexJSON["mcpServers"] as? [String: Any])?["keep"] != nil)
        #expect((codexJSON["mcpServers"] as? [String: Any])?["debrief"] == nil)
        let codexToml = try String(contentsOf: codexConfig, encoding: .utf8)
        #expect(codexToml.contains("[mcp_servers.debrief]"))
        #expect(codexToml.contains("# BEGIN debrief-mcp"))
        #expect((claudeJSON["mcpServers"] as? [String: Any])?["debrief"] != nil)
        #expect(claudeJSON["theme"] as? String == "dark")
        assertInstalledHooks(codexJSON, unrelatedEvent: "PreToolUse")
        assertInstalledHooks(claudeJSON, unrelatedEvent: "Notification")

        for source in [HostSource.codex, .claude] {
            let base = source == .codex
                ? home.appending(path: ".agents/skills")
                : home.appending(path: ".claude/skills")
            for name in EmbeddedTemplates.skillNames {
                let skillPath = base.appending(path: "debrief-\(name)/SKILL.md").path
                #expect(FileManager.default.fileExists(atPath: skillPath))
            }
            let speak = try String(
                contentsOf: base.appending(path: "debrief-speak/SKILL.md"),
                encoding: .utf8
            )
            #expect(speak.contains("speak"))
            #expect(speak.contains("mcp__debrief__speak") || speak.contains("debrief__speak"))
        }
        let grokSkillsRoot = home.appending(path: ".grok/skills")
        for name in EmbeddedTemplates.skillNames {
            let path = grokSkillsRoot.appending(path: "debrief-\(name)/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
        let grokSpeak = try String(
            contentsOf: grokSkillsRoot.appending(path: "debrief-speak/SKILL.md"),
            encoding: .utf8
        )
        #expect(grokSpeak.contains("debrief__speak"))
        #expect(grokSpeak.contains("use_tool") || grokSpeak.contains("search_tool"))
        let grokInstall = try String(
            contentsOf: grokSkillsRoot.appending(path: "debrief-install/SKILL.md"),
            encoding: .utf8
        )
        #expect(grokInstall.contains("debrief__install"))
    }

    @Test func installMergesMcpAndStartHooksOnly() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex/hooks.json")
        let codexConfig = home.appending(path: ".codex/config.toml")
        try writeJSON([
            "mcpServers": ["keep": ["command": "unrelated"]],
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: codex)
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.other]
        command = "/bin/echo"
        enabled = true
        """.utf8).write(to: codexConfig)
        let grokConfig = home.appending(path: ".grok/config.toml")
        try FileManager.default.createDirectory(
            at: grokConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.other]
        command = "/bin/echo"
        enabled = true
        """.utf8).write(to: grokConfig)

        let installer = HostInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/debrief-bin"))
        _ = try installer.install(hosts: Set(HostSource.allCases))

        let codexJSON = try json(at: codex)
        let mcpServers = try #require(codexJSON["mcpServers"] as? [String: Any])
        #expect(mcpServers["keep"] != nil)
        #expect(mcpServers["debrief"] == nil)
        let hooks = try #require(codexJSON["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["SubagentStart"] != nil)
        #expect(hooks["Stop"] == nil)
        #expect(hooks["SubagentStop"] == nil)
        #expect(hooks["PreToolUse"] != nil)

        let codexToml = try String(contentsOf: codexConfig, encoding: .utf8)
        #expect(codexToml.contains("[mcp_servers.other]"))
        #expect(codexToml.contains("[mcp_servers.debrief]"))
        #expect(codexToml.contains("# BEGIN debrief-mcp"))
        #expect(codexToml.contains("# END debrief-mcp"))
        #expect(codexToml.contains("/tmp/debrief-bin"))

        let toml = try String(contentsOf: grokConfig, encoding: .utf8)
        #expect(toml.contains("[mcp_servers.other]"))
        #expect(toml.contains("[mcp_servers.debrief]"))
        #expect(toml.contains("# BEGIN debrief-mcp"))
        #expect(toml.contains("# END debrief-mcp"))
        for name in EmbeddedTemplates.skillNames {
            #expect(FileManager.default.fileExists(
                atPath: home.appending(path: ".grok/skills/debrief-\(name)/SKILL.md").path
            ))
        }
    }

    @Test func uninstallRemovesMcpPreservesOthers() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex/hooks.json")
        let codexConfig = home.appending(path: ".codex/config.toml")
        try writeJSON([
            "mcpServers": ["keep": ["command": "unrelated"]],
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "keep"]]]]],
        ], to: codex)
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.other]
        command = "/bin/echo"
        enabled = true
        """.utf8).write(to: codexConfig)
        let grokConfig = home.appending(path: ".grok/config.toml")
        try FileManager.default.createDirectory(
            at: grokConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.other]
        command = "/bin/echo"
        enabled = true
        """.utf8).write(to: grokConfig)

        let installer = HostInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/debrief-bin"))
        try installer.install(hosts: Set(HostSource.allCases))
        _ = try installer.uninstall(hosts: Set(HostSource.allCases))

        let codexJSON = try json(at: codex)
        let mcpServers = try #require(codexJSON["mcpServers"] as? [String: Any])
        #expect(mcpServers["keep"] != nil)
        #expect(mcpServers["debrief"] == nil)
        let hooks = try #require(codexJSON["hooks"] as? [String: Any])
        #expect(hooks["PreToolUse"] != nil)
        for event in EmbeddedTemplates.hookEvents {
            #expect(hooks[event.rawValue] == nil)
        }

        let codexToml = try String(contentsOf: codexConfig, encoding: .utf8)
        #expect(codexToml.contains("[mcp_servers.other]"))
        #expect(!codexToml.contains("[mcp_servers.debrief]"))
        #expect(!codexToml.contains("# BEGIN debrief-mcp"))

        let toml = try String(contentsOf: grokConfig, encoding: .utf8)
        #expect(toml.contains("[mcp_servers.other]"))
        #expect(!toml.contains("[mcp_servers.debrief]"))
        #expect(!toml.contains("# BEGIN debrief-mcp"))
        for name in EmbeddedTemplates.skillNames {
            #expect(!FileManager.default.fileExists(
                atPath: home.appending(path: ".grok/skills/debrief-\(name)/SKILL.md").path
            ))
        }
    }

    @Test func uninstallRemovesOnlyUnchangedOwnedContent() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HostInstaller(home: home, executable: DebriefPaths.forHome(home).executableURL)
        try installer.install(hosts: Set(HostSource.allCases))
        let modified = home.appending(path: ".agents/skills/debrief-setup/SKILL.md")
        try Data("user edit".utf8).write(to: modified)

        let result = try installer.uninstall(hosts: Set(HostSource.allCases))

        #expect(FileManager.default.fileExists(atPath: modified.path))
        #expect(result.preservedModifiedFiles == [modified.path])
        for settings in [home.appending(path: ".codex/hooks.json"), home.appending(path: ".claude/settings.json")] {
            let hooks = try #require(try json(at: settings)["hooks"] as? [String: Any])
            for event in EmbeddedTemplates.hookEvents {
                #expect(hooks[event.rawValue] == nil)
            }
        }
        let codexToml = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(!codexToml.contains("[mcp_servers.debrief]"))
    }

    @Test func malformedSettingsAreRefusedWithoutBackupOrReplacement() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appending(path: ".codex/hooks.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("[]".utf8)
        try original.write(to: settings)

        #expect(throws: HostInstallerError.settingsRootMustBeObject) {
            try HostInstaller(home: home, executable: DebriefPaths.forHome(home).executableURL)
                .install(hosts: [.codex])
        }
        #expect(try Data(contentsOf: settings) == original)
        #expect(!FileManager.default.fileExists(atPath: settings.path + ".debrief-backup"))
    }

    @Test func installRemovesRetiredOwnedStopHooks() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = URL(fileURLWithPath: "/tmp/debrief-retired-hooks")
        let codex = home.appending(path: ".codex/hooks.json")
        let entry = try jsonObject(EmbeddedTemplates.hookEntry(executable: executable, source: .codex))
        let digest = try InstallerDigest.json(entry)
        try writeJSON([
            "hooks": [
                "Stop": [entry],
                "SubagentStop": [entry],
            ],
        ], to: codex)
        try InstallManifest(hooks: [
            OwnedHook(host: .codex, event: .stop, sha256: digest),
            OwnedHook(host: .codex, event: .subagentStop, sha256: digest),
        ]).save(to: DebriefPaths.forHome(home).installManifestURL)

        _ = try HostInstaller(home: home, executable: executable).install(hosts: [.codex])

        let hooks = try #require(try json(at: codex)["hooks"] as? [String: Any])
        #expect(hooks["Stop"] == nil)
        #expect(hooks["SubagentStop"] == nil)
        #expect(Set(hooks.keys) == Set(EmbeddedTemplates.hookEvents.map(\.rawValue)))
        for event in EmbeddedTemplates.hookEvents {
            #expect((hooks[event.rawValue] as? [Any])?.count == 1)
        }
    }

    @Test func installStripsLegacyOwnedJsonMcpFromCodexHooks() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = URL(fileURLWithPath: "/tmp/debrief-bin")
        let codex = home.appending(path: ".codex/hooks.json")
        let registration = EmbeddedTemplates.mcpRegistration(executable: executable)
        let digest = try InstallerDigest.json(registration)
        try writeJSON([
            "mcpServers": [
                "keep": ["command": "unrelated"],
                "debrief": registration,
            ],
        ], to: codex)
        try InstallManifest(files: [
            OwnedInstalledFile(host: .codex, path: HostInstaller.mcpOwnershipPath(for: .codex), sha256: digest),
        ]).save(to: DebriefPaths.forHome(home).installManifestURL)

        _ = try HostInstaller(home: home, executable: executable).install(hosts: [.codex])

        let mcpServers = try #require(try json(at: codex)["mcpServers"] as? [String: Any])
        #expect(mcpServers["keep"] != nil)
        #expect(mcpServers["debrief"] == nil)
        let toml = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(toml.contains("[mcp_servers.debrief]"))
        #expect(toml.contains("# BEGIN debrief-mcp"))
    }

    @Test func installPreservesForeignTomlMcpOnCodex() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexConfig = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.debrief]
        command = "/usr/local/bin/other-debrief"
        enabled = false
        """.utf8).write(to: codexConfig)

        let result = try HostInstaller(
            home: home,
            executable: URL(fileURLWithPath: "/tmp/debrief-bin")
        ).install(hosts: [.codex])

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        #expect(toml.contains("command = \"/usr/local/bin/other-debrief\""))
        #expect(toml.contains("enabled = false"))
        #expect(!toml.contains("# BEGIN debrief-mcp"))
        #expect(result.preservedModifiedFiles.contains(codexConfig.path)
            || result.preservedModifiedFiles.contains(HostInstaller.mcpOwnershipPath(for: .codex)))
    }

    @Test func installDoesNotClobberUnmanagedGrokDebriefTable() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grokConfig = home.appending(path: ".grok/config.toml")
        try FileManager.default.createDirectory(
            at: grokConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.debrief]
        command = "/usr/local/bin/foreign"
        enabled = false
        """.utf8).write(to: grokConfig)

        let result = try HostInstaller(
            home: home,
            executable: URL(fileURLWithPath: "/tmp/debrief-bin")
        ).install(hosts: [.grok])

        let toml = try String(contentsOf: grokConfig, encoding: .utf8)
        #expect(toml.contains("command = \"/usr/local/bin/foreign\""))
        #expect(toml.contains("enabled = false"))
        #expect(!toml.contains("# BEGIN debrief-mcp"))
        #expect(result.preservedModifiedFiles.contains(grokConfig.path))
        // Skills still install even when foreign MCP table is preserved.
        for name in EmbeddedTemplates.skillNames {
            #expect(FileManager.default.fileExists(
                atPath: home.appending(path: ".grok/skills/debrief-\(name)/SKILL.md").path
            ))
        }
    }

    private func assertInstalledHooks(_ root: [String: Any], unrelatedEvent: String) {
        let hooks = root["hooks"] as? [String: Any]
        #expect(hooks?[unrelatedEvent] != nil)
        for event in EmbeddedTemplates.hookEvents {
            #expect((hooks?[event.rawValue] as? [Any])?.count == 1)
        }
        #expect(hooks?["Stop"] == nil)
        #expect(hooks?["SubagentStop"] == nil)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "debrief-host-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
