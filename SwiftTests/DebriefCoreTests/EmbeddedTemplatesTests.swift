import Foundation
import Testing
@testable import DebriefCore

@Suite("EmbeddedTemplatesTests")
struct EmbeddedTemplatesTests {
    @Test func templatesInstallStartHooksOnlyAndMcpMeta() throws {
        let executable = URL(fileURLWithPath: "/Applications/debrief.app/Contents/MacOS/debrief")

        #expect(Set(EmbeddedTemplates.hookEvents.map(\.rawValue)) == [
            "SessionStart", "UserPromptSubmit", "SubagentStart",
        ])
        #expect(Set(EmbeddedTemplates.skills(executable: executable).keys) == Set(["setup", "install", "speak"]))
        #expect(EmbeddedTemplates.skillNames == ["setup", "install", "speak"])

        let mcp = EmbeddedTemplates.mcpRegistration(executable: executable)
        #expect(mcp["command"] as? String == executable.path)
        #expect(mcp["args"] as? [String] == ["mcp"])

        let toml = EmbeddedTemplates.mcpTomlFragment(executable: executable)
        #expect(toml.contains("[mcp_servers.debrief]"))
        #expect(toml.contains(executable.path))
        #expect(toml.contains(#""mcp""#) || toml.contains("mcp"))
        #expect(toml.contains("tool_timeout_sec = 120"))

        let skill = EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable)
        #expect(skill.contains("debrief__speak"))
        #expect(skill.contains("search_tool") || skill.contains("use_tool"))
        #expect(skill.contains("priority") || skill.contains("lane") || skill.contains("emotion"))
        #expect(skill.contains("companion") || skill.contains("F1"))
        #expect(!skill.contains("chorus:speak"))

        let grokSkills = EmbeddedTemplates.grokSkills(executable: executable)
        #expect(Set(grokSkills.keys) == Set(["setup", "install", "speak"]))
        #expect(grokSkills["install"]?.contains("debrief__install") == true)
        #expect(grokSkills["setup"]?.contains("/mcps") == true)
        #expect(grokSkills["speak"]?.contains("use_tool") == true || grokSkills["speak"]?.contains("debrief__speak") == true)
        #expect(grokSkills["speak"]?.contains("companion") == true || grokSkills["speak"]?.contains("emotion") == true)

        for source in HostSource.allCases {
            let entry = EmbeddedTemplates.hookEntry(executable: executable, source: source)
            #expect(entry.hooks.count == 1)
            #expect(entry.hooks[0].type == "command")
            #expect(
                entry.hooks[0].command
                    == "'/Applications/debrief.app/Contents/MacOS/debrief' hook --source \(source.rawValue)"
            )
            #expect(entry.hooks[0].timeout == 5)
        }

        let combined = EmbeddedTemplates.skills(executable: executable).values.joined(separator: "\n")
            + "\n"
            + EmbeddedTemplates.grokSkills(executable: executable).values.joined(separator: "\n")
        #expect(combined.contains("debrief mute"))
        #expect(combined.contains("debrief doctor"))
        #expect(!combined.localizedCaseInsensitiveContains("menu bar"))
        #expect(!combined.contains("menubar"))
        #expect(combined.localizedCaseInsensitiveContains("mcp") || combined.localizedCaseInsensitiveContains("grok"))
        #expect(combined.contains("mcp__debrief__speak") || combined.contains("speak"))
        #expect(combined.contains("companion") || combined.contains("emotion") || combined.contains("lane"))
        #expect(combined.localizedCaseInsensitiveContains("claude"))
        #expect(!combined.localizedCaseInsensitiveContains("listen mode"))
        #expect(!combined.localizedCaseInsensitiveContains("digest"))
        #expect(!combined.localizedCaseInsensitiveContains("python"))
        #expect(!combined.localizedCaseInsensitiveContains("node_repl"))
    }

    @Test func speakSkillsBriefWhatChangedThenNextAction() {
        let executable = URL(fileURLWithPath: "/Applications/debrief.app/Contents/MacOS/debrief")
        let skills = [
            EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable),
            EmbeddedTemplates.claudeCodexSpeakSkillMarkdown(executable: executable),
        ]
        for skill in skills {
            #expect(skill.contains("what changed"))
            #expect(skill.contains("next action"))
            #expect(skill.contains("Silence only"))
            #expect(skill.contains("do not brief"))
            #expect(!skill.localizedCaseInsensitiveContains("Debrief summarizes"))
        }
    }

    @Test func launchAgentRunsDaemonWithoutAnAppBundle() throws {
        let executable = URL(fileURLWithPath: "/Users/example/.local/bin/debrief")
        let data = try EmbeddedTemplates.launchAgent(executable: executable)
        let value = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(value["Label"] as? String == "com.debrief.tts")
        #expect(value["ProgramArguments"] as? [String] == [executable.path, "daemon"])
        #expect(value["RunAtLoad"] as? Bool == true)
        #expect(value["KeepAlive"] as? Bool == true)
        #expect(value["AssociatedBundleIdentifiers"] == nil)
        #expect(!data.contains(Data("/bin/sh".utf8)))
        #expect(!data.contains(Data("menubar".utf8)))
    }

    @Test func upsertReplacesOwnedBlockAndKeepsOtherEntries() {
        let existing = """
        # BEGIN debrief-mcp
        [mcp_servers.debrief]
        command = "/old/path/debrief"
        # END debrief-mcp

        [mcp_servers.other]
        command = "keep"
        """
        let merged = McpTomlConfig.upsert(
            existing: existing,
            fragment: """
            [mcp_servers.debrief]
            command = "/Applications/debrief.app/Contents/MacOS/debrief"
            """
        )
        #expect(merged.contains("[mcp_servers.other]"))
        #expect(merged.contains("command = \"keep\""))
        #expect(merged.contains("# BEGIN debrief-mcp"))
        #expect(merged.contains("[mcp_servers.debrief]"))
    }
}
