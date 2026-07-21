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

    /// Grok skills live under `~/.grok/skills` (no SessionStart context injection).
    public static func grokSkills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        return [
            "setup": skill(
                name: "chorus-setup",
                description:
                    "Guide local Chorus TTS setup for Grok Build. Prefer skill chorus-install / MCP chorus__install; then chorus-speak at turn end.",
                body: """
                Grok does **not** use SessionStart hook context for speech — durable skills + MCP tools carry the contract.

                1. Run skill **chorus-install** (or shell `\(command) install --grok --repair`).
                2. Refresh MCP with `/mcps` until `chorus__speak` and `chorus__install` appear.
                3. At turn end, use skill **chorus-speak** → MCP `chorus__speak` once.
                4. Mute/mode/diagnostics: Chorus menu bar only.

                Config: `~/.grok/config.toml` section `[mcp_servers.chorus]`.
                Skills dir: `~/.grok/skills/chorus-{setup,install,speak}/`.
                """
            ),
            "install": skill(
                name: "chorus-install",
                description:
                    "Install or repair Chorus.app and Grok MCP registration. Prefer MCP tool chorus__install (search_tool/use_tool); else shell install --grok --repair.",
                body: """
                ## Preferred — MCP (when chorus is already registered)

                1. `search_tool` query: `chorus install` (or `chorus speak`)
                2. `use_tool` tool_name: `chorus__install` with:

                ```json
                { "hosts": ["grok"], "repair": true }
                ```

                - `hosts`: optional `codex` / `claude` / `grok` (omit = all)
                - `repair`: default true

                3. Run **`/mcps`** so Grok reloads tools.

                ## Shell — first install or MCP timeout

                ```bash
                ./scripts/with-xcode.sh swift build -c release
                .build/release/chorus install --grok --repair
                ```

                Or from the app binary:

                ```bash
                \(command) install --grok --repair
                ```

                ## After success

                - Menu bar Chorus running
                - `~/.grok/config.toml` has `# BEGIN chorus-mcp` … `[mcp_servers.chorus]`
                - Skills: chorus-setup, chorus-install, chorus-speak
                - Tools: `chorus__speak`, `chorus__install`
                """
            ),
            "speak": grokSpeakSkillMarkdown(executable: executable),
        ]
    }

    public static func grokSpeakSkillMarkdown(executable: URL) -> String {
        companionSpeakSkillMarkdown(
            title: "Chorus speak (Grok)",
            toolIntro: """
            Grok has **no SessionStart speech context** — this skill is the durable contract.

            1. `search_tool` query `chorus speak` if needed
            2. `use_tool` **`chorus__speak`** with JSON below
            """,
            executable: executable
        )
    }

    /// Durable speak contract for Claude Code / Codex skill directories.
    public static func claudeCodexSpeakSkillMarkdown(executable: URL) -> String {
        companionSpeakSkillMarkdown(
            title: "Chorus speak",
            toolIntro: """
            | Host | Tool |
            | --- | --- |
            | Claude Code | `mcp__chorus__speak` |
            | Codex | `speak` on server `chorus` |
            | Grok | `chorus__speak` (`search_tool` / `use_tool`) |
            """,
            executable: executable
        )
    }

    private static func companionSpeakSkillMarkdown(
        title: String,
        toolIntro: String,
        executable: URL
    ) -> String {
        """
        ---
        name: chorus-speak
        description: Reflective companion TTS via MCP speak (Claude: mcp__chorus__speak; Grok: chorus__speak). Prefer short observation + next step; silence OK; optional lane/emotion.
        ---

        # \(title)

        \(toolIntro)

        Prefer **one short companion line** when speech helps. **Silence is correct** when the turn is pure thrash, repeats the last status, or would only read on-screen lists.

        ## Companion text (default `lane=companion`)

        Structure: **observe** + **meaning** + **one next step or rest**. Prefer voice **F1**, speed ~0.93, volume ~0.85.

        Avoid: file/diff inventories, “completed A/B/C” checklists, chat paste, hype.

        ## When to speak

        Phase boundary, user decision needed, long-session breath, real risk/failure.

        ## Args

        ```json
        {
          "text": "관찰 한 줄. 의미와 다음 한 걸음.",
          "voice": "F1",
          "speed": 0.93,
          "volume": 0.85,
          "priority": "main",
          "lane": "companion",
          "emotion": "neutral"
        }
        ```

        | Field | Required | Notes |
        |-------|----------|--------|
        | text | yes | ≤ 800 chars |
        | voice | yes | F1…M5; companion → F1 |
        | speed | yes | 0.7–2.0 |
        | volume | yes | 0.0–1.0 |
        | priority | no | `main` / `subagent` |
        | lane | no | `companion` (default) / `work` |
        | emotion | no | `neutral` `warm` `focused` `concerned` `relieved` `tired` (restrained; prosody bias only) |

        Work lane: facts only, role voice, prefer `emotion=neutral`. Subagents: `priority=subagent`, prefer `lane=work`.

        Menu: mute · mode · **도우미 음성** · 진단. Binary: `\(executable.path)`.
        """
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        let installSkill = skill(
            name: "chorus-install",
            description:
                "Install or repair Chorus.app, MCP tools (speak/install), and Claude/Codex/Grok host wiring. Prefer MCP install tool when available.",
            body: """
            ## Preferred (when MCP already works)

            Call MCP tool `install` on server `chorus`:

            - Claude: `mcp__chorus__install`
            - Grok: `chorus__install` (`search_tool` / `use_tool`)
            - Codex: tool `install` on server `chorus`

            Arguments:

            - `hosts`: optional array — `\"claude\"`, `\"codex\"`, `\"grok\"` (omit = all)
            - `repair`: boolean, default **true**

            Examples:
            - Claude only: `{ "hosts": ["claude"], "repair": true }`
            - Grok only: `{ "hosts": ["grok"], "repair": true }`

            Then refresh the host (Claude: restart; Grok: `/mcps`).

            ## Shell (first install or MCP timeout)

            ```bash
            ./scripts/with-xcode.sh swift build -c release
            .build/release/chorus install --repair
            # single host: --claude | --codex | --grok
            ```

            Or: `\(command) install --grok --repair`

            ## After install

            1. Host MCP registration for `chorus`
            2. Skills: chorus-setup, chorus-install, chorus-speak
            3. Tools: speak + install (Grok: `chorus__speak` / `chorus__install`)
            """
        )
        return [
            "setup": skill(
                name: "chorus-setup",
                description: "Guide Chorus TTS setup for Claude Code / Codex / Grok (points to install skill and MCP install tool).",
                body: """
                Use skill **chorus-install** or MCP tool `install` \
                (Claude: `mcp__chorus__install`, Grok: `chorus__install`) to install/repair. \
                After wiring, use **chorus-speak** / MCP speak at turn end. \
                Grok: refresh with `/mcps`. Mute/mode/diagnostics are menu bar only. Binary: `\(command)`.
                """
            ),
            "install": installSkill,
            "speak": claudeCodexSpeakSkillMarkdown(executable: executable),
        ]
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
