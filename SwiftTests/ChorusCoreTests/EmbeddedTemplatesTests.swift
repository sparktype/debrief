import Foundation
import Testing
@testable import ChorusCore

@Suite("EmbeddedTemplatesTests")
struct EmbeddedTemplatesTests {
    @Test func templatesInstallStartHooksOnlyAndMcpMeta() throws {
        let executable = URL(fileURLWithPath: "/Applications/Chorus.app/Contents/MacOS/chorus")

        #expect(Set(EmbeddedTemplates.hookEvents.map(\.rawValue)) == [
            "SessionStart", "UserPromptSubmit", "SubagentStart",
        ])
        #expect(Set(EmbeddedTemplates.skills(executable: executable).keys) == Set(["setup", "install", "speak"]))
        #expect(EmbeddedTemplates.skillNames == ["setup", "install", "speak"])

        let mcp = EmbeddedTemplates.mcpRegistration(executable: executable)
        #expect(mcp["command"] as? String == executable.path)
        #expect(mcp["args"] as? [String] == ["mcp"])

        let toml = EmbeddedTemplates.mcpTomlFragment(executable: executable)
        #expect(toml.contains("[mcp_servers.chorus]"))
        #expect(toml.contains(executable.path))
        #expect(toml.contains(#""mcp""#) || toml.contains("mcp"))
        #expect(toml.contains("tool_timeout_sec = 120"))

        let skill = EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable)
        #expect(skill.contains("chorus__speak"))
        #expect(skill.contains("search_tool") || skill.contains("use_tool"))
        #expect(skill.contains("priority") || skill.contains("lane") || skill.contains("emotion"))
        #expect(skill.contains("companion") || skill.contains("F1"))
        #expect(!skill.contains("chorus:speak"))

        let grokSkills = EmbeddedTemplates.grokSkills(executable: executable)
        #expect(Set(grokSkills.keys) == Set(["setup", "install", "speak"]))
        #expect(grokSkills["install"]?.contains("chorus__install") == true)
        #expect(grokSkills["setup"]?.contains("/mcps") == true)
        #expect(grokSkills["speak"]?.contains("use_tool") == true || grokSkills["speak"]?.contains("chorus__speak") == true)
        #expect(grokSkills["speak"]?.contains("companion") == true || grokSkills["speak"]?.contains("emotion") == true)

        for source in HostSource.allCases {
            let entry = EmbeddedTemplates.hookEntry(executable: executable, source: source)
            #expect(entry.hooks.count == 1)
            #expect(entry.hooks[0].type == "command")
            #expect(
                entry.hooks[0].command
                    == "'/Applications/Chorus.app/Contents/MacOS/chorus' hook --source \(source.rawValue)"
            )
            #expect(entry.hooks[0].timeout == 5)
        }

        let combined = EmbeddedTemplates.skills(executable: executable).values.joined(separator: "\n")
        #expect(combined.localizedCaseInsensitiveContains("menu bar"))
        #expect(combined.localizedCaseInsensitiveContains("mcp") || combined.localizedCaseInsensitiveContains("grok"))
        #expect(combined.contains("mcp__chorus__speak") || combined.contains("speak"))
        #expect(combined.contains("companion") || combined.contains("emotion") || combined.contains("lane"))
        #expect(combined.localizedCaseInsensitiveContains("claude"))
        #expect(!combined.localizedCaseInsensitiveContains("listen mode"))
        #expect(!combined.localizedCaseInsensitiveContains("digest"))
        #expect(!combined.localizedCaseInsensitiveContains("python"))
        #expect(!combined.localizedCaseInsensitiveContains("node_repl"))
    }

    @Test func launchAgentRunsOnlyTheInstalledBinary() throws {
        let executable = URL(fileURLWithPath: "/Applications/Chorus.app/Contents/MacOS/chorus")
        let data = try EmbeddedTemplates.launchAgent(executable: executable)
        let value = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(value["Label"] as? String == "com.chorus.tts")
        #expect(value["ProgramArguments"] as? [String] == [executable.path, "menubar"])
        #expect(value["RunAtLoad"] as? Bool == true)
        #expect(value["KeepAlive"] as? Bool == true)
        // BTM "Allow in the Background" resolves icons via the associated app bundle.
        #expect(value["AssociatedBundleIdentifiers"] as? [String] == ["com.chorus.tts"])
        #expect(!data.contains(Data("/bin/sh".utf8)))
    }

    @Test func appInfoPlistDeclaresIconNameForSystemUI() throws {
        let data = try EmbeddedTemplates.appInfoPlist(version: "2.0.0")
        let value = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(value["CFBundleIconFile"] as? String == "AppIcon")
        #expect(value["CFBundleIconName"] as? String == "AppIcon")
        #expect(value["CFBundleIdentifier"] as? String == "com.chorus.tts")
    }
}
