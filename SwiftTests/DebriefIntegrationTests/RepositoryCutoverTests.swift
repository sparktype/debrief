import Foundation
import Testing

@Suite("RepositoryCutoverTests")
struct RepositoryCutoverTests {
    /// Speech is MCP-only; plugin hooks are start-family context injectors.
    private let expectedEvents = Set([
        "SessionStart",
        "UserPromptSubmit",
        "SubagentStart",
    ])

    @Test func legacyRuntimeIsAbsent() {
        for path in ["hook_voice", "tts_server", "plugins/debrief/runtime"] {
            #expect(!FileManager.default.fileExists(atPath: repositoryRoot.appending(path: path).path))
        }
    }

    @Test func pluginHooksUseOnlyTheSwiftExecutable() throws {
        for path in [
            "plugins/debrief/hooks/hooks.json",
            "plugins/debrief/hooks/claude-hooks.json",
        ] {
            let manifest = try jsonObject(path)
            let hooks = try #require(manifest["hooks"] as? [String: Any])
            #expect(Set(hooks.keys) == expectedEvents)

            for groups in hooks.values {
                for group in try #require(groups as? [[String: Any]]) {
                    for hook in try #require(group["hooks"] as? [[String: Any]]) {
                        let command = try #require(hook["command"] as? String)
                        // Sample hooks name the installed executable. HostInstaller rewrites the absolute path.
                        #expect(command.contains("hook --source"))
                        #expect(command.contains(".local/bin/debrief"))
                        #expect(!command.contains("debrief.app"))
                        #expect(!command.contains("python"))
                        #expect(!command.contains("hook_voice"))
                    }
                }
            }
        }
    }

    @Test func activePluginAndCurrentDocsDoNotAdvertiseRemovedRuntime() throws {
        let paths = [
            ".agents/plugins/marketplace.json",
            "plugins/debrief/.codex-plugin/plugin.json",
            "plugins/debrief/.claude-plugin/plugin.json",
            "plugins/debrief/hooks/hooks.json",
            "plugins/debrief/hooks/claude-hooks.json",
            "README.md",
            "ONBOARDING.md",
            "DEVELOPER.md",
        ] + skillFiles
        let text = try paths
            .map { try String(contentsOf: repositoryRoot.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!text.localizedCaseInsensitiveContains("node_repl"))
        #expect(!text.localizedCaseInsensitiveContains("listen mode"))
        #expect(!text.localizedCaseInsensitiveContains("external summary provider"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var skillFiles: [String] {
        let skills = repositoryRoot.appending(path: "plugins/debrief/skills")
        return ((try? FileManager.default.contentsOfDirectory(
            at: skills,
            includingPropertiesForKeys: nil
        )) ?? []).map { "plugins/debrief/skills/\($0.lastPathComponent)/SKILL.md" }
    }

    private func jsonObject(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appending(path: path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
