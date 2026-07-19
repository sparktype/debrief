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
    /// Start-family hooks only — speech is MCP `speak`, not Stop extraction.
    public static let hookEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .subagentStart,
    ]
    /// User control is the menu bar; only setup remains for install/repair guidance.
    public static let skillNames = ["setup"]

    public static func hookEntry(executable: URL, source: HostSource) -> EmbeddedHookEntry {
        EmbeddedHookEntry(hooks: [
            EmbeddedHookHandler(
                type: "command",
                command: "\(shellQuote(executable.path)) hook --source \(source.rawValue)",
                timeout: 2
            ),
        ])
    }

    public static func mcpRegistration(executable: URL) -> [String: Any] {
        [
            "command": executable.path,
            "args": ["mcp"],
        ]
    }

    public static func grokMcpTomlFragment(executable: URL) -> String {
        """
        [mcp_servers.chorus]
        command = "\(tomlString(executable.path))"
        args = ["mcp"]
        enabled = true
        startup_timeout_sec = 15
        tool_timeout_sec = 10
        """
    }

    public static func grokSpeakSkillMarkdown(executable: URL) -> String {
        """
        ---
        name: chorus-speak
        description: Speak a short finish summary through local Chorus TTS via MCP tool chorus__speak. Use at end of a turn when a spoken one- or two-sentence summary helps.
        ---

        # Chorus speak

        When you finish a turn that deserves a spoken summary, call the MCP tool on server `chorus`:

        - Grok qualified name: `chorus__speak` (via `search_tool` / `use_tool` if required)
        - Required arguments: `text`, `voice`, `speed`, `volume`
        - Default main voice: `F1`, speed near `0.93`, volume near `0.85`
        - Do **not** put HTML comments or JSON speech metadata in the assistant message body.
        - Mute/mode are controlled only from the Chorus menu bar.

        Binary: `\(executable.path)`.
        """
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        return [
            "setup": skill(
                name: "chorus-setup",
                description: "Install or repair local Chorus TTS (Chorus.app), MCP speak registration, and host hooks.",
                body: """
                Run `\(command) install --repair` from a Chorus build if the app is missing or broken. \
                Mute, mode, start/stop, and quit are controlled only from the Chorus menu bar — there is no user CLI. \
                Speech uses the local MCP tool `speak` on server `chorus` (Grok: `chorus__speak`); hosts register it via install. \
                For Codex, remind the user to review hook definitions in `/hooks`. \
                For Grok, MCP lives in `~/.grok/config.toml`; refresh tools with `/mcps` after install.
                """
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

    /// Finder / LaunchServices metadata for `Chorus.app`.
    public static func appInfoPlist(version: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Chorus",
                "CFBundleExecutable": AppBundleInstaller.executableName,
                "CFBundleIconFile": AppBundleInstaller.iconFileName,
                "CFBundleIdentifier": AppBundleInstaller.bundleIdentifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Chorus",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": version,
                "LSMinimumSystemVersion": "14.0",
                // Menu bar agent: no Dock tile; Applications icon still launches the app.
                "LSUIElement": true,
                // Prefer a single running instance when the user re-clicks the app icon.
                "LSMultipleInstancesProhibited": true,
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
            ] as [String: Any],
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

    private static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
