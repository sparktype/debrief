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
        for path in ["hook_voice", "tts_server", "plugins/chorus/runtime"] {
            #expect(!FileManager.default.fileExists(atPath: repositoryRoot.appending(path: path).path))
        }
    }

    @Test func pluginHooksUseOnlyTheSwiftExecutable() throws {
        for path in [
            "plugins/chorus/hooks/hooks.json",
            "plugins/chorus/hooks/claude-hooks.json",
        ] {
            let manifest = try jsonObject(path)
            let hooks = try #require(manifest["hooks"] as? [String: Any])
            #expect(Set(hooks.keys) == expectedEvents)

            for groups in hooks.values {
                for group in try #require(groups as? [[String: Any]]) {
                    for hook in try #require(group["hooks"] as? [[String: Any]]) {
                        let command = try #require(hook["command"] as? String)
                        // Production path is the app binary (quoted absolute path); bare PATH `chorus` is gone.
                        #expect(command.contains("hook --source"))
                        #expect(command.contains("Chorus.app/Contents/MacOS/chorus"))
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
            "plugins/chorus/.codex-plugin/plugin.json",
            "plugins/chorus/.claude-plugin/plugin.json",
            "plugins/chorus/hooks/hooks.json",
            "plugins/chorus/hooks/claude-hooks.json",
            "README.md",
            "ONBOARDING.md",
            "DEVELOPER.md",
        ] + skillFiles
        let text = try paths
            .map { try String(contentsOf: repositoryRoot.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!text.localizedCaseInsensitiveContains("node_repl"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var skillFiles: [String] {
        let skills = repositoryRoot.appending(path: "plugins/chorus/skills")
        return ((try? FileManager.default.contentsOfDirectory(
            at: skills,
            includingPropertiesForKeys: nil
        )) ?? []).map { "plugins/chorus/skills/\($0.lastPathComponent)/SKILL.md" }
    }

    private func jsonObject(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appending(path: path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
