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
        #expect(Set(EmbeddedTemplates.skills(executable: executable).keys) == Set(["setup", "speak"]))
        #expect(EmbeddedTemplates.skillNames == ["setup", "speak"])

        let mcp = EmbeddedTemplates.mcpRegistration(executable: executable)
        #expect(mcp["command"] as? String == executable.path)
        #expect(mcp["args"] as? [String] == ["mcp"])

        let toml = EmbeddedTemplates.mcpTomlFragment(executable: executable)
        #expect(toml.contains("[mcp_servers.chorus]"))
        #expect(toml.contains(executable.path))
        #expect(toml.contains(#""mcp""#) || toml.contains("mcp"))

        let skill = EmbeddedTemplates.grokSpeakSkillMarkdown(executable: executable)
        #expect(skill.contains("chorus__speak") || skill.contains("`speak`"))
        #expect(!skill.contains("chorus:speak"))

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
