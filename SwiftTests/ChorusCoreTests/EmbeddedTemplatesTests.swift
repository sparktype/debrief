import Foundation
import Testing
@testable import ChorusCore

@Suite("EmbeddedTemplatesTests")
struct EmbeddedTemplatesTests {
    @Test func templatesContainOnlyFiveHooksAndSixTTSSkills() throws {
        let executable = URL(fileURLWithPath: "/Users/test/.local/bin/chorus")

        #expect(Set(EmbeddedTemplates.hookEvents) == Set(HookEventName.allCases))
        #expect(Set(EmbeddedTemplates.skills(executable: executable).keys) == Set([
            "setup", "status", "mode", "mute", "speak", "doctor",
        ]))

        for source in HostSource.allCases {
            let entry = EmbeddedTemplates.hookEntry(executable: executable, source: source)
            #expect(entry.hooks.count == 1)
            #expect(entry.hooks[0].type == "command")
            #expect(entry.hooks[0].command == "'/Users/test/.local/bin/chorus' hook --source \(source.rawValue)")
            #expect(entry.hooks[0].timeout == 2)
        }

        let combined = EmbeddedTemplates.skills(executable: executable).values.joined(separator: "\n")
        #expect(!combined.localizedCaseInsensitiveContains("listen"))
        #expect(!combined.localizedCaseInsensitiveContains("digest"))
        #expect(!combined.localizedCaseInsensitiveContains("python"))
        #expect(!combined.localizedCaseInsensitiveContains("node_repl"))
    }

    @Test func launchAgentRunsOnlyTheInstalledBinary() throws {
        let executable = URL(fileURLWithPath: "/Users/test/.local/bin/chorus")
        let data = try EmbeddedTemplates.launchAgent(executable: executable)
        let value = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(value["Label"] as? String == "com.chorus.tts")
        #expect(value["ProgramArguments"] as? [String] == [executable.path, "menubar"])
        #expect(value["RunAtLoad"] as? Bool == true)
        #expect(value["KeepAlive"] as? Bool == true)
        #expect(!data.contains(Data("/bin/sh".utf8)))
    }
}
