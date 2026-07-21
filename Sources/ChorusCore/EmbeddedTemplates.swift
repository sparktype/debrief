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
    /// setup = guidance; install = MCP/shell install action; speak = MCP speak contract.
    public static let skillNames = ["setup", "install", "speak"]

    public static func hookEntry(executable: URL, source: HostSource) -> EmbeddedHookEntry {
        EmbeddedHookEntry(hooks: [
            EmbeddedHookHandler(
                type: "command",
                command: "\(shellQuote(executable.path)) hook --source \(source.rawValue)",
                // Cold launch of the app binary can exceed 2s on first use.
                timeout: 5
            ),
        ])
    }

    public static func mcpRegistration(executable: URL) -> [String: Any] {
        [
            "command": executable.path,
            "args": ["mcp"],
        ]
    }

    /// Shared TOML MCP fragment for Codex (`~/.codex/config.toml`) and Grok (`~/.grok/config.toml`).
    public static func mcpTomlFragment(executable: URL) -> String {
        """
        [mcp_servers.chorus]
        command = "\(tomlString(executable.path))"
        args = ["mcp"]
        enabled = true
        startup_timeout_sec = 15
        tool_timeout_sec = 120
        """
    }

    public static func grokSpeakSkillMarkdown(executable: URL) -> String {
        speakSkillMarkdown(
            toolLine: "Grok qualified name: `chorus__speak` (via `search_tool` / `use_tool` if required)",
            executable: executable
        )
    }

    /// Durable speak contract for Claude Code / Codex skill directories.
    public static func claudeCodexSpeakSkillMarkdown(executable: URL) -> String {
        speakSkillMarkdown(
            toolLine: """
            - Claude Code: server `chorus`, tool `speak` (often listed as `mcp__chorus__speak`)
            - Codex: server `chorus`, tool `speak`
            """,
            executable: executable
        )
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        let installSkill = skill(
            name: "chorus-install",
            description:
                "Install or repair Chorus.app, MCP tools (speak/install), and Claude/Codex/Grok hooks. Prefer MCP tool install (mcp__chorus__install) when available.",
            body: """
            ## Preferred (when MCP already works)

            Call MCP tool `install` on server `chorus` (Claude: `mcp__chorus__install`):

            - `hosts`: optional array — `\"claude\"`, `\"codex\"`, `\"grok\"` (omit = all)
            - `repair`: boolean, default **true**

            Example (Claude only repair):
            `install` with `{ "hosts": ["claude"], "repair": true }`

            Then **restart Claude Code** so tools refresh.

            ## Shell (first install or MCP timeout)

            From a Chorus build tree:

            ```bash
            ./scripts/with-xcode.sh swift build -c release
            .build/release/chorus install --claude --repair
            # all hosts: .build/release/chorus install --repair
            ```

            Or re-run from the installed app:

            ```bash
            \(command) install --claude --repair
            ```

            ## After install

            1. `mcpServers.chorus` in host settings
            2. Start-family hooks present
            3. Skills: chorus-setup, chorus-install, chorus-speak
            4. Tools: `speak` / `install` (Claude may show `mcp__chorus__*`)
            """
        )
        return [
            "setup": skill(
                name: "chorus-setup",
                description: "Guide Chorus TTS setup for Claude Code / Codex / Grok (points to install skill and MCP install tool).",
                body: """
                Use skill **chorus-install** or MCP tool `install` (`mcp__chorus__install`) to install/repair. \
                After wiring, use **chorus-speak** / MCP `speak` at turn end. \
                Mute/mode/diagnostics are menu bar only. Binary: `\(command)`.
                """
            ),
            "install": installSkill,
            "speak": claudeCodexSpeakSkillMarkdown(executable: executable),
        ]
    }

    private static func speakSkillMarkdown(toolLine: String, executable: URL) -> String {
        """
        ---
        name: chorus-speak
        description: Speak a short finish summary through local Chorus TTS via MCP tool speak (Claude: mcp__chorus__speak). Use at end of a turn when a spoken one- or two-sentence summary helps.
        ---

        # Chorus speak

        When you finish a turn that deserves a spoken summary, call the Chorus MCP tool **once**:

        \(toolLine)
        - Required arguments: `text`, `voice`, `speed`, `volume`
        - Optional: `priority` = `main` (default) or `subagent` (use for background/subagents; suppressed in focus/quiet/night)
        - Default main voice: `F1`, speed near `0.93`, volume near `0.85`
        - Keep `text` ≤ 800 characters, natural spoken Korean or English
        - Do **not** put HTML comments or JSON speech metadata in the assistant message body
        - Omitting the tool is silence — the user will not hear a summary
        - Mute/mode/diagnostics are controlled only from the Chorus menu bar

        Binary: `\(executable.path)`.
        """
    }

    public static func launchAgent(executable: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.chorus.tts",
                "ProgramArguments": [executable.path, "menubar"],
                "RunAtLoad": true,
                "KeepAlive": true,
                // macOS BTM / "Allow in the Background" uses this to show the app icon.
                "AssociatedBundleIdentifiers": [AppBundleInstaller.bundleIdentifier],
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
                // Modern System Settings / BTM prefer IconName alongside IconFile.
                "CFBundleIconName": AppBundleInstaller.iconFileName,
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
