// 훅/스킬 마크다운, MCP 등록 메타데이터, LaunchAgent plist — 모두 바이너리 안에 내장된 텍스트
use crate::hook_event::HookEventName;
use crate::hook_event::HostSource;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct EmbeddedHookHandler {
    pub r#type: String,
    pub command: String,
    pub timeout: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EmbeddedHookEntry {
    pub hooks: Vec<EmbeddedHookHandler>,
}

pub struct EmbeddedTemplates;

impl EmbeddedTemplates {
    /// 시작 계열 훅만 설치한다 — 발화는 Stop 추출이 아니라 MCP `speak`다.
    pub const HOOK_EVENTS: [HookEventName; 3] =
        [HookEventName::SessionStart, HookEventName::UserPromptSubmit, HookEventName::SubagentStart];
    /// setup = 안내, install = MCP/셸 설치 동작, speak = MCP speak 계약.
    pub const SKILL_NAMES: [&'static str; 3] = ["setup", "install", "speak"];

    pub fn hook_entry(executable: &Path, source: HostSource) -> EmbeddedHookEntry {
        EmbeddedHookEntry {
            hooks: vec![EmbeddedHookHandler {
                r#type: "command".to_string(),
                command: format!("{} hook --source {}", Self::shell_quote(&executable.to_string_lossy()), source.as_str()),
                // 최초 실행 시 콜드 스타트가 2초를 넘을 수 있다.
                timeout: 5,
            }],
        }
    }

    pub fn mcp_registration(executable: &Path) -> (String, Vec<String>) {
        (executable.to_string_lossy().to_string(), vec!["mcp".to_string()])
    }

    /// Codex(`~/.codex/config.toml`)와 Grok(`~/.grok/config.toml`)이 공유하는 TOML MCP 조각.
    pub fn mcp_toml_fragment(executable: &Path) -> String {
        format!(
            "[mcp_servers.debrief]\ncommand = \"{}\"\nargs = [\"mcp\"]\nenabled = true\nstartup_timeout_sec = 15\ntool_timeout_sec = 120",
            Self::toml_string(&executable.to_string_lossy())
        )
    }

    /// Grok 스킬은 `~/.grok/skills`에 있다 (SessionStart 컨텍스트 주입 없음).
    pub fn grok_skills(executable: &Path) -> Vec<(&'static str, String)> {
        let command = Self::shell_quote(&executable.to_string_lossy());
        vec![
            (
                "setup",
                Self::skill(
                    "debrief-setup",
                    "Guide local debrief TTS setup for Grok Build. Prefer skill debrief-install / MCP debrief__install; then debrief-speak at turn end.",
                    &format!(
                        "Grok does **not** use SessionStart hook context for speech — durable skills + MCP tools carry the contract.\n\n\
1. Run skill **debrief-install** (or shell `{command} install --grok --repair`).\n\
2. Refresh MCP with `/mcps` until `debrief__speak` and `debrief__install` appear.\n\
3. At turn end, use skill **debrief-speak** → MCP `debrief__speak` once: what changed, then one next action.\n\
4. Mute, mode, companion, and diagnostics: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`.\n\n\
Config: `~/.grok/config.toml` section `[mcp_servers.debrief]`.\n\
Skills dir: `~/.grok/skills/debrief-{{setup,install,speak}}/`."
                    ),
                ),
            ),
            (
                "install",
                Self::skill(
                    "debrief-install",
                    "Install or repair the debrief daemon and Grok MCP registration. Prefer MCP tool debrief__install (search_tool/use_tool); else shell install --grok --repair.",
                    &format!(
                        "## Preferred — MCP (when debrief is already registered)\n\n\
1. `search_tool` query: `debrief install` (or `debrief speak`)\n\
2. `use_tool` tool_name: `debrief__install` with:\n\n\
```json\n{{ \"hosts\": [\"grok\"], \"repair\": true }}\n```\n\n\
- `hosts`: optional `codex` / `claude` / `grok` (omit = all)\n\
- `repair`: default true\n\n\
3. Run **`/mcps`** so Grok reloads tools.\n\n\
## Shell — first install or MCP timeout\n\n\
```bash\ndebrief install --grok --repair\n```\n\n\
Or the installed executable:\n\n\
```bash\n{command} install --grok --repair\n```\n\n\
## After success\n\n\
- LaunchAgent running `debrief daemon`\n\
- `~/.grok/config.toml` has `# BEGIN debrief-mcp` … `[mcp_servers.debrief]`\n\
- Skills: debrief-setup, debrief-install, debrief-speak\n\
- Tools: `debrief__speak`, `debrief__install`"
                    ),
                ),
            ),
            ("speak", Self::grok_speak_skill_markdown(executable)),
        ]
    }

    pub fn grok_speak_skill_markdown(executable: &Path) -> String {
        Self::companion_speak_skill_markdown(
            "debrief speak (Grok)",
            "Grok has **no SessionStart speech context** — this skill is the durable contract.\n\n\
1. `search_tool` query `debrief speak` if needed\n\
2. `use_tool` **`debrief__speak`** with JSON below",
            executable,
        )
    }

    /// Claude Code / Codex 스킬 디렉터리를 위한 영속 speak 계약.
    pub fn claude_codex_speak_skill_markdown(executable: &Path) -> String {
        Self::companion_speak_skill_markdown(
            "debrief speak",
            "| Host | Tool |\n| --- | --- |\n\
| Claude Code | `mcp__debrief__speak` |\n\
| Codex | `speak` on server `debrief` |\n\
| Grok | `debrief__speak` (`search_tool` / `use_tool`) |",
            executable,
        )
    }

    fn companion_speak_skill_markdown(title: &str, tool_intro: &str, executable: &Path) -> String {
        format!(
            "---\n\
name: debrief-speak\n\
description: Turn-end spoken briefing via MCP speak (Claude: mcp__debrief__speak; Grok: debrief__speak). Use when a user-visible turn ends.\n\
---\n\n\
# {title}\n\n\
{tool_intro}\n\n\
At the end of each user-visible turn, call speak **once**. Two short sentences in the user's language: **what changed**, then the one **next action** or wait. The agent writes the line. **Silence only** if nothing new and no next action.\n\n\
## Code ownership\n\n\
After writing, changing, or analyzing code, protect the user's code ownership and keep cognitive debt low. Make the **next action** the one thing they must verify themselves: a behavior change, a deletion, a security or data path, an assumption you made, or how to check or undo. Skip it for trivial changes; then brief as usual. Subagents never do this.\n\n\
## Shape (`lane=companion`)\n\n\
The server rotates the companion voice across F1–M5, one voice per session, and keeps it. Pass `session` when the hook names a host session id. Speed ~0.93, volume ~0.85. Work lane keeps the voice you pass. No file lists, checklists, or chat paste.\n\n\
## Args\n\n\
```json\n\
{{\n  \"text\": \"무엇이 바뀌었는지. 다음 행동은 이것.\",\n  \"voice\": \"F1\",\n  \"speed\": 0.93,\n  \"volume\": 0.85,\n  \"priority\": \"main\",\n  \"lane\": \"companion\",\n  \"emotion\": \"neutral\",\n  \"session\": \"host-session-id\"\n}}\n\
```\n\n\
| Field | Required | Notes |\n\
|-------|----------|--------|\n\
| text | yes | ≤ 800 chars. Sentence one: what changed. Sentence two: next action. |\n\
| voice | yes | F1…M5. Companion playback uses the session rotation. Work lane uses this value. |\n\
| session | no | Host session id. The same id keeps the same companion voice. |\n\
| speed | yes | 0.7–2.0 |\n\
| volume | yes | 0.0–1.0 |\n\
| priority | no | `main` / `subagent` |\n\
| lane | no | `companion` (default) / `work` |\n\
| emotion | no | `neutral` `warm` `focused` `concerned` `relieved` `tired` (prosody bias only) |\n\n\
Work lane: facts only, role voice, prefer `emotion=neutral`. Subagents **do not brief** the user, but speak once when their work is done: `priority=subagent`, `lane=work`, one fact.\n\n\
Controls: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`. Binary: `{executable}`.",
            title = title,
            tool_intro = tool_intro,
            executable = executable.to_string_lossy(),
        )
    }

    pub fn skills(executable: &Path) -> Vec<(&'static str, String)> {
        let command = Self::shell_quote(&executable.to_string_lossy());
        let install_skill = Self::skill(
            "debrief-install",
            "Install or repair the debrief daemon, MCP tools (speak/install), and Claude/Codex/Grok host wiring. Prefer MCP install tool when available.",
            &format!(
                "## Preferred (when MCP already works)\n\n\
Call MCP tool `install` on server `debrief`:\n\n\
- Claude: `mcp__debrief__install`\n\
- Grok: `debrief__install` (`search_tool` / `use_tool`)\n\
- Codex: tool `install` on server `debrief`\n\n\
Arguments:\n\n\
- `hosts`: optional array — `\"claude\"`, `\"codex\"`, `\"grok\"` (omit = all)\n\
- `repair`: boolean, default **true**\n\n\
Examples:\n\
- Claude only: `{{ \"hosts\": [\"claude\"], \"repair\": true }}`\n\
- Grok only: `{{ \"hosts\": [\"grok\"], \"repair\": true }}`\n\n\
Then refresh the host (Claude: restart; Grok: `/mcps`).\n\n\
## Shell (first install or MCP timeout)\n\n\
```bash\ndebrief install --repair\n# single host: --claude | --codex | --grok\n```\n\n\
Or: `{command} install --grok --repair`\n\n\
## After install\n\n\
1. Host MCP registration for `debrief`\n\
2. Skills: debrief-setup, debrief-install, debrief-speak\n\
3. Tools: speak + install (Grok: `debrief__speak` / `debrief__install`)"
            ),
        );
        vec![
            (
                "setup",
                Self::skill(
                    "debrief-setup",
                    "Guide debrief TTS setup for Claude Code / Codex / Grok (points to install skill and MCP install tool).",
                    &format!(
                        "Use skill **debrief-install** or MCP tool `install` (Claude: `mcp__debrief__install`, Grok: `debrief__install`) to install/repair. \
After wiring, use **debrief-speak** at turn end: what changed, then one next action. \
Grok: refresh with `/mcps`. Mute, mode, companion, and diagnostics: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`. Binary: `{command}`."
                    ),
                ),
            ),
            ("install", install_skill),
            ("speak", Self::claude_codex_speak_skill_markdown(executable)),
        ]
    }

    pub fn launch_agent(executable: &Path) -> String {
        let path = Self::xml_escape(&executable.to_string_lossy());
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
<plist version=\"1.0\">\n\
<dict>\n\
\t<key>Label</key>\n\
\t<string>com.debrief.tts</string>\n\
\t<key>ProgramArguments</key>\n\
\t<array>\n\
\t\t<string>{path}</string>\n\
\t\t<string>daemon</string>\n\
\t</array>\n\
\t<key>RunAtLoad</key>\n\
\t<true/>\n\
\t<key>KeepAlive</key>\n\
\t<true/>\n\
</dict>\n\
</plist>\n"
        )
    }

    fn skill(name: &str, description: &str, body: &str) -> String {
        format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\n{body}")
    }

    fn shell_quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\\''"))
    }

    fn toml_string(value: &str) -> String {
        value.replace('\\', "\\\\").replace('"', "\\\"")
    }

    fn xml_escape(value: &str) -> String {
        value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_install_start_hooks_only_and_mcp_meta() {
        let executable = Path::new("/Applications/debrief.app/Contents/MacOS/debrief");

        let event_names: std::collections::HashSet<_> =
            EmbeddedTemplates::HOOK_EVENTS.iter().map(|e| e.as_str()).collect();
        assert_eq!(
            event_names,
            ["SessionStart", "UserPromptSubmit", "SubagentStart"].into_iter().collect()
        );
        let skill_keys: std::collections::HashSet<_> =
            EmbeddedTemplates::skills(executable).into_iter().map(|(k, _)| k).collect();
        assert_eq!(skill_keys, ["setup", "install", "speak"].into_iter().collect());
        assert_eq!(EmbeddedTemplates::SKILL_NAMES, ["setup", "install", "speak"]);

        let (command, args) = EmbeddedTemplates::mcp_registration(executable);
        assert_eq!(command, executable.to_string_lossy());
        assert_eq!(args, vec!["mcp".to_string()]);

        let toml = EmbeddedTemplates::mcp_toml_fragment(executable);
        assert!(toml.contains("[mcp_servers.debrief]"));
        assert!(toml.contains(&executable.to_string_lossy().to_string()));
        assert!(toml.contains("mcp"));
        assert!(toml.contains("tool_timeout_sec = 120"));

        let skill = EmbeddedTemplates::grok_speak_skill_markdown(executable);
        assert!(skill.contains("debrief__speak"));
        assert!(skill.contains("search_tool") || skill.contains("use_tool"));
        assert!(skill.contains("priority") || skill.contains("lane") || skill.contains("emotion"));
        assert!(skill.contains("companion") || skill.contains("F1"));
        assert!(!skill.contains("chorus:speak"));

        let grok_skills: std::collections::HashMap<_, _> = EmbeddedTemplates::grok_skills(executable).into_iter().collect();
        let grok_keys: std::collections::HashSet<_> = grok_skills.keys().copied().collect();
        assert_eq!(grok_keys, ["setup", "install", "speak"].into_iter().collect());
        assert!(grok_skills["install"].contains("debrief__install"));
        assert!(grok_skills["setup"].contains("/mcps"));
        assert!(grok_skills["speak"].contains("use_tool") || grok_skills["speak"].contains("debrief__speak"));
        assert!(grok_skills["speak"].contains("companion") || grok_skills["speak"].contains("emotion"));

        for source in [HostSource::Codex, HostSource::Claude, HostSource::Grok] {
            let entry = EmbeddedTemplates::hook_entry(executable, source);
            assert_eq!(entry.hooks.len(), 1);
            assert_eq!(entry.hooks[0].r#type, "command");
            assert_eq!(
                entry.hooks[0].command,
                format!("'/Applications/debrief.app/Contents/MacOS/debrief' hook --source {}", source.as_str())
            );
            assert_eq!(entry.hooks[0].timeout, 5);
        }

        let combined = EmbeddedTemplates::skills(executable)
            .into_iter()
            .map(|(_, v)| v)
            .chain(EmbeddedTemplates::grok_skills(executable).into_iter().map(|(_, v)| v))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(combined.contains("debrief mute"));
        assert!(combined.contains("debrief doctor"));
        assert!(!combined.to_lowercase().contains("menu bar"));
        assert!(!combined.contains("menubar"));
        assert!(combined.to_lowercase().contains("mcp") || combined.to_lowercase().contains("grok"));
        assert!(combined.contains("mcp__debrief__speak") || combined.contains("speak"));
        assert!(combined.contains("companion") || combined.contains("emotion") || combined.contains("lane"));
        assert!(combined.to_lowercase().contains("claude"));
        assert!(!combined.to_lowercase().contains("listen mode"));
        assert!(!combined.to_lowercase().contains("digest"));
        assert!(!combined.to_lowercase().contains("python"));
        assert!(!combined.to_lowercase().contains("node_repl"));
    }

    #[test]
    fn speak_skills_brief_what_changed_then_next_action() {
        let executable = Path::new("/Applications/debrief.app/Contents/MacOS/debrief");
        for skill in [
            EmbeddedTemplates::grok_speak_skill_markdown(executable),
            EmbeddedTemplates::claude_codex_speak_skill_markdown(executable),
        ] {
            assert!(skill.contains("what changed"));
            assert!(skill.contains("next action"));
            assert!(skill.contains("Silence only"));
            assert!(skill.contains("do not brief"));
            assert!(skill.contains("when their work is done"));
            assert!(skill.contains("ownership"));
            assert!(!skill.to_lowercase().contains("debrief summarizes"));
        }
    }

    #[test]
    fn launch_agent_runs_daemon_without_an_app_bundle() {
        let executable = Path::new("/Users/example/.local/bin/debrief");
        let plist = EmbeddedTemplates::launch_agent(executable);

        assert!(plist.contains("<key>Label</key>"));
        assert!(plist.contains("<string>com.debrief.tts</string>"));
        assert!(plist.contains("<string>/Users/example/.local/bin/debrief</string>"));
        assert!(plist.contains("<string>daemon</string>"));
        assert!(plist.contains("<key>RunAtLoad</key>\n\t<true/>"));
        assert!(plist.contains("<key>KeepAlive</key>\n\t<true/>"));
        assert!(!plist.contains("AssociatedBundleIdentifiers"));
        assert!(!plist.contains("/bin/sh"));
        assert!(!plist.contains("menubar"));
    }
}
