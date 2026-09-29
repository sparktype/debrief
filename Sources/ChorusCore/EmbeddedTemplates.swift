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
                // Cold launch of the executable can exceed 2s on first use.
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
        [mcp_servers.debrief]
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
                name: "debrief-setup",
                description:
                    "Guide local debrief TTS setup for Grok Build. Prefer skill debrief-install / MCP debrief__install; then debrief-speak at turn end.",
                body: """
                Grok does **not** use SessionStart hook context for speech — durable skills + MCP tools carry the contract.

                1. Run skill **debrief-install** (or shell `\(command) install --grok --repair`).
                2. Refresh MCP with `/mcps` until `debrief__speak` and `debrief__install` appear.
                3. At turn end, use skill **debrief-speak** → MCP `debrief__speak` once: what changed, then one next action.
                4. Mute, mode, companion, and diagnostics: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`.

                Config: `~/.grok/config.toml` section `[mcp_servers.debrief]`.
                Skills dir: `~/.grok/skills/debrief-{setup,install,speak}/`.
                """
            ),
            "install": skill(
                name: "debrief-install",
                description:
                    "Install or repair the debrief daemon and Grok MCP registration. Prefer MCP tool debrief__install (search_tool/use_tool); else shell install --grok --repair.",
                body: """
                ## Preferred — MCP (when debrief is already registered)

                1. `search_tool` query: `debrief install` (or `debrief speak`)
                2. `use_tool` tool_name: `debrief__install` with:

                ```json
                { "hosts": ["grok"], "repair": true }
                ```

                - `hosts`: optional `codex` / `claude` / `grok` (omit = all)
                - `repair`: default true

                3. Run **`/mcps`** so Grok reloads tools.

                ## Shell — first install or MCP timeout

                ```bash
                debrief install --grok --repair
                ```

                Or the installed executable:

                ```bash
                \(command) install --grok --repair
                ```

                ## After success

                - LaunchAgent running `debrief daemon`
                - `~/.grok/config.toml` has `# BEGIN debrief-mcp` … `[mcp_servers.debrief]`
                - Skills: debrief-setup, debrief-install, debrief-speak
                - Tools: `debrief__speak`, `debrief__install`
                """
            ),
            "speak": grokSpeakSkillMarkdown(executable: executable),
        ]
    }

    public static func grokSpeakSkillMarkdown(executable: URL) -> String {
        companionSpeakSkillMarkdown(
            title: "debrief speak (Grok)",
            toolIntro: """
            Grok has **no SessionStart speech context** — this skill is the durable contract.

            1. `search_tool` query `debrief speak` if needed
            2. `use_tool` **`debrief__speak`** with JSON below
            """,
            executable: executable
        )
    }

    /// Durable speak contract for Claude Code / Codex skill directories.
    public static func claudeCodexSpeakSkillMarkdown(executable: URL) -> String {
        companionSpeakSkillMarkdown(
            title: "debrief speak",
            toolIntro: """
            | Host | Tool |
            | --- | --- |
            | Claude Code | `mcp__debrief__speak` |
            | Codex | `speak` on server `debrief` |
            | Grok | `debrief__speak` (`search_tool` / `use_tool`) |
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
        name: debrief-speak
        description: Turn-end spoken briefing via MCP speak (Claude: mcp__debrief__speak; Grok: debrief__speak). Use when a user-visible turn ends.
        ---

        # \(title)

        \(toolIntro)

        At the end of each user-visible turn, call speak **once**. Two short sentences in the user's language: **what changed**, then the one **next action** or wait. The agent writes the line. **Silence only** if nothing new and no next action.

        ## Shape (`lane=companion`, voice **F1**)

        Speed ~0.93, volume ~0.85. No file lists, checklists, or chat paste.

        ## Args

        ```json
        {
          "text": "무엇이 바뀌었는지. 다음 행동은 이것.",
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
        | text | yes | ≤ 800 chars. Sentence one: what changed. Sentence two: next action. |
        | voice | yes | F1…M5; companion → F1 |
        | speed | yes | 0.7–2.0 |
        | volume | yes | 0.0–1.0 |
        | priority | no | `main` / `subagent` |
        | lane | no | `companion` (default) / `work` |
        | emotion | no | `neutral` `warm` `focused` `concerned` `relieved` `tired` (prosody bias only) |

        Work lane: facts only, role voice, prefer `emotion=neutral`. Subagents **do not brief** the user. If they speak: `priority=subagent`, `lane=work`, one fact.

        Controls: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`. Binary: `\(executable.path)`.
        """
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        let installSkill = skill(
            name: "debrief-install",
            description:
                "Install or repair the debrief daemon, MCP tools (speak/install), and Claude/Codex/Grok host wiring. Prefer MCP install tool when available.",
            body: """
            ## Preferred (when MCP already works)

            Call MCP tool `install` on server `debrief`:

            - Claude: `mcp__debrief__install`
            - Grok: `debrief__install` (`search_tool` / `use_tool`)
            - Codex: tool `install` on server `debrief`

            Arguments:

            - `hosts`: optional array — `\"claude\"`, `\"codex\"`, `\"grok\"` (omit = all)
            - `repair`: boolean, default **true**

            Examples:
            - Claude only: `{ "hosts": ["claude"], "repair": true }`
            - Grok only: `{ "hosts": ["grok"], "repair": true }`

            Then refresh the host (Claude: restart; Grok: `/mcps`).

            ## Shell (first install or MCP timeout)

            ```bash
            debrief install --repair
            # single host: --claude | --codex | --grok
            ```

            Or: `\(command) install --grok --repair`

            ## After install

            1. Host MCP registration for `debrief`
            2. Skills: debrief-setup, debrief-install, debrief-speak
            3. Tools: speak + install (Grok: `debrief__speak` / `debrief__install`)
            """
        )
        return [
            "setup": skill(
                name: "debrief-setup",
                description: "Guide debrief TTS setup for Claude Code / Codex / Grok (points to install skill and MCP install tool).",
                body: """
                Use skill **debrief-install** or MCP tool `install` \
                (Claude: `mcp__debrief__install`, Grok: `debrief__install`) to install/repair. \
                After wiring, use **debrief-speak** at turn end: what changed, then one next action. \
                Grok: refresh with `/mcps`. Mute, mode, companion, and diagnostics: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`. Binary: `\(command)`.
                """
            ),
            "install": installSkill,
            "speak": claudeCodexSpeakSkillMarkdown(executable: executable),
        ]
    }

    public static func launchAgent(executable: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.debrief.tts",
                "ProgramArguments": [executable.path, "daemon"],
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

    private static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
