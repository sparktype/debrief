import Foundation

public struct EmbeddedHookHandler: Codable, Equatable, Sendable {
    public let type: String
    public let command: String
    public let timeout: Int
}

public struct EmbeddedHookEntry: Codable, Equatable, Sendable {
    public let hooks: [EmbeddedHookHandler]
}

public enum EmbeddedTemplates {
    public static let hookEvents = HookEventName.allCases
    public static let skillNames = ["setup", "status", "mode", "mute", "speak", "doctor"]

    public static func hookEntry(executable: URL, source: HostSource) -> EmbeddedHookEntry {
        EmbeddedHookEntry(hooks: [
            EmbeddedHookHandler(
                type: "command",
                command: "\(shellQuote(executable.path)) hook --source \(source.rawValue)",
                timeout: 2
            ),
        ])
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        return [
            "setup": skill(
                name: "chorus-setup",
                description: "Install or repair local Chorus TTS and host integration.",
                body: "Run `\(command) install --repair`. For Codex, remind the user to review the exact hook definitions in `/hooks`."
            ),
            "status": skill(
                name: "chorus-status",
                description: "Show the current local Chorus TTS state.",
                body: "Run `\(command) status` and report the current resident process, model, hook, mute, and mode state."
            ),
            "mode": skill(
                name: "chorus-mode",
                description: "Change the Chorus TTS speaking mode.",
                body: "Run `\(command) mode <normal|focus|quiet|verbose|night>`. The mode may suppress speech or lower volume but never replaces agent-selected voice or speed."
            ),
            "mute": skill(
                name: "chorus-mute",
                description: "Mute, unmute, or toggle Chorus TTS.",
                body: "Run `\(command) mute <on|off|toggle>` and report the resulting local mute state."
            ),
            "speak": skill(
                name: "chorus-speak",
                description: "Speak explicit text through local Chorus TTS.",
                body: "Run `\(command) speak --text <text> --voice <F1-F5|M1-M5> --speed <0.7-2.0> --volume <0-1>`. Text, voice, speed, and volume are all required and selected by the agent."
            ),
            "doctor": skill(
                name: "chorus-doctor",
                description: "Diagnose local Chorus TTS installation failures.",
                body: "Run `\(command) doctor`. Report each current-state check and its exact recovery command. Do not play audio unless explicitly requested."
            ),
        ]
    }

    public static func launchAgent(executable: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.chorus.tts",
                "ProgramArguments": [executable.path, "menubar"],
                "RunAtLoad": true,
                "KeepAlive": true,
            ],
            format: .xml,
            options: 0
        )
    }

    private static func skill(name: String, description: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        \(body)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
