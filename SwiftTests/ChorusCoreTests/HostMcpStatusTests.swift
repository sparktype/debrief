// Host MCP wiring probe + menu line tests
import Foundation
import Testing
@testable import ChorusCore

@Suite("HostMcpStatusTests")
struct HostMcpStatusTests {
    @Test func absentWhenConfigMissing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL

        let claude = HostMcpProbe.status(for: .claude, home: home, expectedExecutable: expected)
        #expect(claude.state == .absent)
        #expect(!claude.isProblem)
        #expect(claude.menuLine.hasPrefix("⚪"))
        #expect(claude.menuLine.contains("Claude"))
        #expect(claude.menuLine.contains("설정 없음"))
    }

    @Test func claudeOkWhenCommandMatches() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeClaude(home: home, command: expected.path)

        let status = HostMcpProbe.status(for: .claude, home: home, expectedExecutable: expected)
        #expect(status.state == .ok)
        #expect(!status.isProblem)
        #expect(status.menuLine.hasPrefix("✅"))
        #expect(status.menuLine.contains("등록됨"))
    }

    @Test func claudeMissingWhenNoChorusEntry() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeJSON(["mcpServers": ["other": ["command": "/bin/true"]]], to: claudeSettings(home))

        let status = HostMcpProbe.status(for: .claude, home: home, expectedExecutable: expected)
        #expect(status.state == .missing)
        #expect(status.isProblem)
        #expect(status.menuLine.hasPrefix("⚠️"))
        #expect(status.menuLine.contains("미등록"))
    }

    @Test func claudeStalePathWhenCommandDiffers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeClaude(home: home, command: "/old/path/chorus")

        let status = HostMcpProbe.status(for: .claude, home: home, expectedExecutable: expected)
        #expect(status.state == .stalePath)
        #expect(status.isProblem)
        #expect(status.menuLine.hasPrefix("🔄"))
        #expect(status.menuLine.contains("경로 불일치"))
    }

    @Test func claudeUnreadableWhenInvalidJSON() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try FileManager.default.createDirectory(
            at: claudeSettings(home).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: claudeSettings(home))

        let status = HostMcpProbe.status(for: .claude, home: home, expectedExecutable: expected)
        #expect(status.state == .unreadable)
        #expect(status.isProblem)
        #expect(status.menuLine.hasPrefix("❌"))
    }

    @Test func codexOkFromTomlTable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeCodexToml(home: home, command: expected.path)

        let status = HostMcpProbe.status(for: .codex, home: home, expectedExecutable: expected)
        #expect(status.state == .ok)
        #expect(status.menuLine.contains("Codex"))
    }

    @Test func codexIgnoresHooksJsonMcp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        // hooks.json has chorus MCP but config.toml does not — must be missing.
        try writeJSON(
            ["mcpServers": ["debrief": ["command": expected.path, "args": ["mcp"]]]],
            to: home.appending(path: ".codex/hooks.json")
        )
        try FileManager.default.createDirectory(
            at: home.appending(path: ".codex", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("# empty\n".utf8).write(to: home.appending(path: ".codex/config.toml"))

        let status = HostMcpProbe.status(for: .codex, home: home, expectedExecutable: expected)
        #expect(status.state == .missing)
    }

    @Test func grokStalePathFromToml() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeGrokToml(home: home, command: "/wrong/chorus")

        let status = HostMcpProbe.status(for: .grok, home: home, expectedExecutable: expected)
        #expect(status.state == .stalePath)
    }

    @Test func statusesReturnsAllHostsInStableOrder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        let all = HostMcpProbe.statuses(home: home, expectedExecutable: expected)
        #expect(all.map(\.host) == HostSource.allCases)
    }

    @Test func problemHostsFiltersOkAndAbsent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = ChorusPaths.forHome(home).executableURL
        try writeClaude(home: home, command: expected.path) // ok
        try writeCodexToml(home: home, command: "/stale") // stale
        // grok absent
        let problems = HostMcpProbe.problemHosts(home: home, expectedExecutable: expected)
        #expect(problems == [.codex])
    }

    // MARK: - helpers

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeSettings(_ home: URL) -> URL {
        home.appending(path: ".claude/settings.json")
    }

    private func writeClaude(home: URL, command: String) throws {
        try writeJSON(
            [
                "mcpServers": [
                    "debrief": [
                        "command": command,
                        "args": ["mcp"],
                    ],
                ],
            ],
            to: claudeSettings(home)
        )
    }

    private func writeCodexToml(home: URL, command: String) throws {
        let url = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = """
        # BEGIN debrief-mcp
        [mcp_servers.debrief]
        command = "\(command)"
        args = ["mcp"]
        # END debrief-mcp
        """
        try Data(body.utf8).write(to: url)
    }

    private func writeGrokToml(home: URL, command: String) throws {
        let url = home.appending(path: ".grok/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = """
        [mcp_servers.debrief]
        command = "\(command)"
        args = ["mcp"]
        """
        try Data(body.utf8).write(to: url)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
