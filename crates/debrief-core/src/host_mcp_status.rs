// 에이전트별 MCP 배선 상태 probe (debrief doctor)
use crate::hook_event::HostSource;
use crate::mcp_toml_config::McpTomlConfig;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostMcpState {
    Ok,
    Missing,
    Absent,
    Unreadable,
    StalePath,
}

impl HostMcpState {
    fn as_str(&self) -> &'static str {
        match self {
            HostMcpState::Ok => "ok",
            HostMcpState::Missing => "missing",
            HostMcpState::Absent => "absent",
            HostMcpState::Unreadable => "unreadable",
            HostMcpState::StalePath => "stalePath",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostMcpStatus {
    pub host: HostSource,
    pub state: HostMcpState,
}

impl HostMcpStatus {
    pub fn is_problem(&self) -> bool {
        match self.state {
            HostMcpState::Ok | HostMcpState::Absent => false,
            HostMcpState::Missing | HostMcpState::Unreadable | HostMcpState::StalePath => true,
        }
    }

    pub fn state_emoji(&self) -> &'static str {
        match self.state {
            HostMcpState::Ok => "✅",
            HostMcpState::Absent => "⚪",
            HostMcpState::Missing => "⚠️",
            HostMcpState::Unreadable => "❌",
            HostMcpState::StalePath => "🔄",
        }
    }

    pub fn host_display_name(&self) -> &'static str {
        match self.host {
            HostSource::Claude => "Claude",
            HostSource::Codex => "Codex",
            HostSource::Grok => "Grok",
        }
    }

    pub fn state_label(&self) -> &'static str {
        match self.state {
            HostMcpState::Ok => "등록됨",
            HostMcpState::Absent => "설정 없음",
            HostMcpState::Missing => "미등록",
            HostMcpState::Unreadable => "설정 읽기 실패",
            HostMcpState::StalePath => "경로 불일치",
        }
    }

    pub fn menu_line(&self) -> String {
        format!("{} {}: {}", self.state_emoji(), self.host_display_name(), self.state_label())
    }

    pub fn recovery(&self) -> Option<String> {
        if !self.is_problem() {
            return None;
        }
        let flag = match self.host {
            HostSource::Claude => "--claude",
            HostSource::Codex => "--codex",
            HostSource::Grok => "--grok",
        };
        match self.state {
            HostMcpState::Unreadable => Some(format!("에이전트 설정을 수정한 뒤 debrief install {flag} --repair")),
            HostMcpState::Missing | HostMcpState::StalePath => Some(format!("debrief install {flag} --repair")),
            HostMcpState::Ok | HostMcpState::Absent => None,
        }
    }

    pub fn doctor_code(&self) -> String {
        format!("mcp.{}.{}", self.host.as_str(), self.state.as_str())
    }
}

/// 파일시스템만 들여다보는 순수 probe (호스트 MCP 등록 상태).
pub struct HostMcpProbe;

impl HostMcpProbe {
    pub fn statuses(home: &Path, expected_executable: &Path) -> Vec<HostMcpStatus> {
        [HostSource::Codex, HostSource::Claude, HostSource::Grok]
            .into_iter()
            .map(|host| Self::status(host, home, expected_executable))
            .collect()
    }

    pub fn problem_hosts(home: &Path, expected_executable: &Path) -> std::collections::HashSet<HostSource> {
        Self::statuses(home, expected_executable)
            .into_iter()
            .filter(|status| status.is_problem())
            .map(|status| status.host)
            .collect()
    }

    pub fn status(host: HostSource, home: &Path, expected_executable: &Path) -> HostMcpStatus {
        let state = match host {
            HostSource::Claude => Self::probe_claude(home, expected_executable),
            HostSource::Codex => Self::probe_toml(&home.join(".codex/config.toml"), expected_executable),
            HostSource::Grok => Self::probe_toml(&home.join(".grok/config.toml"), expected_executable),
        };
        HostMcpStatus { host, state }
    }

    // MARK: - Claude JSON

    fn probe_claude(home: &Path, expected: &Path) -> HostMcpState {
        // Claude Code는 사용자 범위 MCP 서버를 ~/.claude.json에서 읽는다, settings.json이 아니다.
        let url = home.join(".claude.json");
        if !url.exists() {
            return HostMcpState::Absent;
        }
        let Ok(data) = std::fs::read(&url) else { return HostMcpState::Unreadable };
        let Ok(serde_json::Value::Object(root)) = serde_json::from_slice::<serde_json::Value>(&data) else {
            return HostMcpState::Unreadable;
        };
        let Some(serde_json::Value::Object(mcp_servers)) = root.get("mcpServers") else {
            return HostMcpState::Missing;
        };
        let Some(serde_json::Value::Object(debrief)) = mcp_servers.get("debrief") else {
            return HostMcpState::Missing;
        };
        let Some(serde_json::Value::String(command)) = debrief.get("command") else {
            return HostMcpState::Missing;
        };
        if command.is_empty() {
            return HostMcpState::Missing;
        }
        if Self::paths_match(command, expected) {
            HostMcpState::Ok
        } else {
            HostMcpState::StalePath
        }
    }

    // MARK: - Codex / Grok TOML

    fn probe_toml(config_url: &Path, expected: &Path) -> HostMcpState {
        if !config_url.exists() {
            return HostMcpState::Absent;
        }
        let Ok(text) = std::fs::read_to_string(config_url) else { return HostMcpState::Unreadable };

        let table_body = if let Some(owned) = McpTomlConfig::owned_fragment(&text) {
            if McpTomlConfig::has_debrief_table(&owned) || owned.contains("[mcp_servers.debrief]") {
                Some(owned)
            } else {
                None
            }
        } else if McpTomlConfig::has_debrief_table(&text) {
            Some(text.clone())
        } else {
            None
        };

        let Some(table_body) = table_body else { return HostMcpState::Missing };
        let Some(command) = Self::extract_toml_command(&table_body) else { return HostMcpState::Missing };
        if Self::paths_match(&command, expected) {
            HostMcpState::Ok
        } else {
            HostMcpState::StalePath
        }
    }

    /// TOML 조각에서 `command = "..."`를 best-effort로 추출한다.
    fn extract_toml_command(text: &str) -> Option<String> {
        // 파일 전체를 스캔할 때는 [mcp_servers.debrief] 아래 값을 우선한다.
        let section = match text.find("[mcp_servers.debrief]") {
            Some(index) => &text[index..],
            None => text,
        };
        for line in section.lines() {
            let trimmed = line.trim_start();
            if let Some(rest) = trimmed.strip_prefix("command") {
                let rest = rest.trim_start();
                let Some(rest) = rest.strip_prefix('=') else { continue };
                let rest = rest.trim_start();
                if let Some(value) = Self::parse_toml_quoted_string(rest) {
                    return Some(Self::unescape_toml_string(&value));
                }
            }
        }
        None
    }

    /// `"..."` 선행 부분을 파싱한다 (이스케이프된 `\"`와 `\\` 지원).
    fn parse_toml_quoted_string(rest: &str) -> Option<String> {
        let mut chars = rest.chars();
        if chars.next() != Some('"') {
            return None;
        }
        let mut result = String::new();
        let mut escaped = false;
        for c in chars {
            if escaped {
                result.push(c);
                escaped = false;
                continue;
            }
            match c {
                '\\' => escaped = true,
                '"' => return Some(result),
                _ => result.push(c),
            }
        }
        None
    }

    fn unescape_toml_string(value: &str) -> String {
        value.replace("\\\\", "\\").replace("\\\"", "\"")
    }

    fn paths_match(command: &str, expected: &Path) -> bool {
        let left = std::fs::canonicalize(command).unwrap_or_else(|_| PathBuf::from(command));
        let right = std::fs::canonicalize(expected).unwrap_or_else(|_| expected.to_path_buf());
        left == right
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn make_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = std::env::temp_dir().join(format!("debrief-mcp-probe-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    fn write_json(value: &serde_json::Value, url: &Path) {
        fs::create_dir_all(url.parent().unwrap()).unwrap();
        fs::write(url, serde_json::to_vec_pretty(value).unwrap()).unwrap();
    }

    fn write_claude(home: &Path, command: &str) {
        write_json(
            &serde_json::json!({"mcpServers": {"debrief": {"command": command, "args": ["mcp"]}}}),
            &home.join(".claude.json"),
        );
    }

    fn write_codex_toml(home: &Path, command: &str) {
        let url = home.join(".codex/config.toml");
        fs::create_dir_all(url.parent().unwrap()).unwrap();
        fs::write(&url, format!("# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"{command}\"\nargs = [\"mcp\"]\n# END debrief-mcp")).unwrap();
    }

    fn write_grok_toml(home: &Path, command: &str) {
        let url = home.join(".grok/config.toml");
        fs::create_dir_all(url.parent().unwrap()).unwrap();
        fs::write(&url, format!("[mcp_servers.debrief]\ncommand = \"{command}\"\nargs = [\"mcp\"]")).unwrap();
    }

    #[test]
    fn absent_when_config_missing() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        let claude = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(claude.state, HostMcpState::Absent);
        assert!(!claude.is_problem());
        assert!(claude.menu_line().starts_with('⚪'));
        assert!(claude.menu_line().contains("Claude"));
        assert!(claude.menu_line().contains("설정 없음"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_ok_when_command_matches() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        fs::create_dir_all(expected.parent().unwrap()).unwrap();
        fs::write(&expected, "binary").unwrap();
        write_claude(&home, &expected.to_string_lossy());

        let status = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(status.state, HostMcpState::Ok);
        assert!(!status.is_problem());
        assert!(status.menu_line().starts_with('✅'));
        assert!(status.menu_line().contains("등록됨"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_missing_when_no_debrief_entry() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        write_json(&serde_json::json!({"mcpServers": {"other": {"command": "/bin/true"}}}), &home.join(".claude.json"));

        let status = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(status.state, HostMcpState::Missing);
        assert!(status.is_problem());
        assert!(status.menu_line().starts_with('⚠'));
        assert!(status.menu_line().contains("미등록"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_ignores_legacy_settings_json_mcp() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        // 예전 설치가 남긴 settings.json 등록은 Claude Code가 읽지 않으므로 등록으로 치지 않는다.
        write_json(
            &serde_json::json!({"mcpServers": {"debrief": {"command": expected.to_string_lossy(), "args": ["mcp"]}}}),
            &home.join(".claude/settings.json"),
        );
        write_json(&serde_json::json!({"mcpServers": {}}), &home.join(".claude.json"));

        let status = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(status.state, HostMcpState::Missing);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_stale_path_when_command_differs() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        write_claude(&home, "/old/path/debrief");

        let status = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(status.state, HostMcpState::StalePath);
        assert!(status.is_problem());
        assert!(status.menu_line().starts_with('🔄'));
        assert!(status.menu_line().contains("경로 불일치"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_unreadable_when_invalid_json() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        let settings = home.join(".claude.json");
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, "not-json").unwrap();

        let status = HostMcpProbe::status(HostSource::Claude, &home, &expected);
        assert_eq!(status.state, HostMcpState::Unreadable);
        assert!(status.is_problem());
        assert!(status.menu_line().starts_with('❌'));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn codex_ok_from_toml_table() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        fs::create_dir_all(expected.parent().unwrap()).unwrap();
        fs::write(&expected, "binary").unwrap();
        write_codex_toml(&home, &expected.to_string_lossy());

        let status = HostMcpProbe::status(HostSource::Codex, &home, &expected);
        assert_eq!(status.state, HostMcpState::Ok);
        assert!(status.menu_line().contains("Codex"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn codex_ignores_hooks_json_mcp() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        write_json(
            &serde_json::json!({"mcpServers": {"debrief": {"command": expected.to_string_lossy(), "args": ["mcp"]}}}),
            &home.join(".codex/hooks.json"),
        );
        fs::create_dir_all(home.join(".codex")).unwrap();
        fs::write(home.join(".codex/config.toml"), "# empty\n").unwrap();

        let status = HostMcpProbe::status(HostSource::Codex, &home, &expected);
        assert_eq!(status.state, HostMcpState::Missing);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn grok_stale_path_from_toml() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        write_grok_toml(&home, "/wrong/debrief");

        let status = HostMcpProbe::status(HostSource::Grok, &home, &expected);
        assert_eq!(status.state, HostMcpState::StalePath);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn statuses_returns_all_hosts_in_stable_order() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        let all = HostMcpProbe::statuses(&home, &expected);
        assert_eq!(all.iter().map(|s| s.host).collect::<Vec<_>>(), vec![HostSource::Codex, HostSource::Claude, HostSource::Grok]);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn problem_hosts_filters_ok_and_absent() {
        let home = make_home();
        let expected = crate::paths::DebriefPaths::for_home(&home).executable_url;
        fs::create_dir_all(expected.parent().unwrap()).unwrap();
        fs::write(&expected, "binary").unwrap();
        write_claude(&home, &expected.to_string_lossy());
        write_codex_toml(&home, "/stale");

        let problems = HostMcpProbe::problem_hosts(&home, &expected);
        assert_eq!(problems, [HostSource::Codex].into_iter().collect());
        fs::remove_dir_all(&home).ok();
    }
}
