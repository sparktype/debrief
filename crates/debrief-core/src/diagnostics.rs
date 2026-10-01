// 데몬/모델/호스트 설정 상태를 모아 `debrief status`/`debrief doctor`에 보여주는 진단
use crate::configuration::{DebriefConfiguration, DebriefMode};
use crate::hook_event::HostSource;
use crate::host_mcp_status::{HostMcpProbe, HostMcpStatus};
use crate::install_manifest::{AtomicInstallerFile, InstallManifest};
use crate::model_installer::InstalledModel;
use crate::model_manifest::ModelManifest;
use crate::paths::DebriefPaths;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DaemonProcessState {
    Missing,
    Running,
    Stale,
    Invalid,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StatusSnapshot {
    pub mode: DebriefMode,
    pub muted: bool,
    pub companion_enabled: bool,
    pub process: DaemonProcessState,
    pub socket_present: bool,
    pub model_revision: Option<String>,
    pub model_valid: bool,
    pub launch_agent_installed: bool,
    pub host_settings_readable: std::collections::HashMap<&'static str, bool>,
    pub owned_hook_count: usize,
    pub owned_skill_count: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DiagnosticFinding {
    pub code: String,
    pub ok: bool,
    pub recovery: Option<String>,
}

impl DiagnosticFinding {
    /// `debrief doctor`용 짧은 한국어 한 줄.
    pub fn summary_line(&self) -> String {
        let status = if self.ok { "정상" } else { "문제" };
        if let Some(recovery) = &self.recovery {
            if !self.ok {
                return format!("[{status}] {} — {recovery}", self.code);
            }
        }
        format!("[{status}] {}", self.code)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CurrentError {
    pub timestamp: String,
    pub component: String,
    pub code: String,
    pub message: String,
}

impl CurrentError {
    pub const MAXIMUM_MESSAGE_LENGTH: usize = 160;
}

pub struct Diagnostics<'a> {
    paths: DebriefPaths,
    process_exists: Box<dyn Fn(i32) -> bool + 'a>,
}

impl<'a> Diagnostics<'a> {
    pub fn new(home: &Path) -> Self {
        Self::with_process_check(home, Self::live_process_exists)
    }

    pub fn with_process_check(home: &Path, process_exists: impl Fn(i32) -> bool + 'a) -> Self {
        Diagnostics { paths: DebriefPaths::for_home(home), process_exists: Box::new(process_exists) }
    }

    pub fn status(&self) -> StatusSnapshot {
        let configuration = DebriefConfiguration::load(&self.paths.config_url);
        let process = self.process_state();
        let (model_revision, model_valid) = self.model_state();
        let manifest = InstallManifest::load(&self.paths.install_manifest_url).unwrap_or_default();

        let mut host_settings_readable = std::collections::HashMap::new();
        host_settings_readable.insert(
            "codex",
            Self::settings_readable(&self.paths.home.join(".codex/hooks.json"))
                && Self::settings_readable_toml(&self.paths.home.join(".codex/config.toml")),
        );
        host_settings_readable.insert("claude", Self::settings_readable(&self.paths.home.join(".claude/settings.json")));
        host_settings_readable.insert("grok", Self::settings_readable_toml(&self.paths.home.join(".grok/config.toml")));

        StatusSnapshot {
            mode: configuration.mode,
            muted: configuration.muted,
            companion_enabled: configuration.companion_enabled,
            process,
            socket_present: self.paths.socket_url.exists(),
            model_revision,
            model_valid,
            launch_agent_installed: self.paths.launch_agent_url.exists(),
            host_settings_readable,
            owned_hook_count: manifest.hooks.len(),
            owned_skill_count: manifest.files.len(),
        }
    }

    /// CLI `debrief status` 출력줄. 데몬이 꺼져 있어도 0으로 종료한다.
    pub fn status_text(&self) -> String {
        let snapshot = self.status();
        let process = match snapshot.process {
            DaemonProcessState::Running => "실행 중",
            DaemonProcessState::Missing => "없음",
            DaemonProcessState::Stale => "오래된 pid",
            DaemonProcessState::Invalid => "잘못된 pid",
        };
        let model = match &snapshot.model_revision {
            Some(revision) => {
                if snapshot.model_valid {
                    revision.clone()
                } else {
                    format!("{revision} (사용할 수 없음)")
                }
            }
            None => "없음".to_string(),
        };
        format!(
            "프로세스: {process}\n음소거: {}\n모드: {}\n도우미 음성: {}\n모델: {model}\n소켓: {}\nLaunchAgent: {}",
            if snapshot.muted { "켜짐" } else { "꺼짐" },
            snapshot.mode.as_str(),
            if snapshot.companion_enabled { "켜짐" } else { "꺼짐" },
            if snapshot.socket_present { "있음" } else { "없음" },
            if snapshot.launch_agent_installed { "설치됨" } else { "없음" },
        )
    }

    pub fn doctor(&self) -> Vec<DiagnosticFinding> {
        let snapshot = self.status();
        let recovery = Self::operational_recovery(&snapshot);
        let mut findings = Vec::new();

        match snapshot.process {
            DaemonProcessState::Running => findings.push(DiagnosticFinding { code: "daemon.running".to_string(), ok: true, recovery: None }),
            DaemonProcessState::Stale => {
                findings.push(DiagnosticFinding { code: "daemon.stale_pid".to_string(), ok: false, recovery: Some(recovery.clone()) })
            }
            DaemonProcessState::Invalid => {
                findings.push(DiagnosticFinding { code: "daemon.invalid_pid".to_string(), ok: false, recovery: Some(recovery.clone()) })
            }
            DaemonProcessState::Missing => {
                findings.push(DiagnosticFinding { code: "daemon.missing".to_string(), ok: false, recovery: Some(recovery.clone()) })
            }
        }

        if snapshot.model_revision.is_none() {
            findings.push(DiagnosticFinding { code: "model.missing".to_string(), ok: false, recovery: Some(recovery.clone()) });
        } else if !snapshot.model_valid {
            findings.push(DiagnosticFinding { code: "model.invalid_marker".to_string(), ok: false, recovery: Some(recovery.clone()) });
        } else {
            findings.push(DiagnosticFinding { code: "model.valid".to_string(), ok: true, recovery: None });
        }

        let mcp_statuses = self.host_mcp_statuses();
        let unreadable_mcp_hosts: std::collections::HashSet<_> =
            mcp_statuses.iter().filter(|s| s.state == crate::host_mcp_status::HostMcpState::Unreadable).map(|s| s.host).collect();
        for host in [HostSource::Codex, HostSource::Claude, HostSource::Grok] {
            if snapshot.host_settings_readable.get(host.as_str()) == Some(&false) {
                // MCP probe가 이미 다루면 단일 mcp.*.unreadable을 우선한다.
                if unreadable_mcp_hosts.contains(&host) {
                    continue;
                }
                findings.push(self.host_settings_finding(host));
            }
        }
        for mcp in mcp_statuses.iter().filter(|s| s.is_problem()) {
            findings.push(DiagnosticFinding { code: mcp.doctor_code(), ok: false, recovery: mcp.recovery() });
        }

        findings.push(DiagnosticFinding {
            code: if snapshot.socket_present { "socket.present".to_string() } else { "socket.missing".to_string() },
            ok: snapshot.socket_present,
            recovery: if snapshot.socket_present { None } else { Some(recovery.clone()) },
        });
        findings.push(DiagnosticFinding {
            code: if snapshot.launch_agent_installed { "launch_agent.installed".to_string() } else { "launch_agent.missing".to_string() },
            ok: snapshot.launch_agent_installed,
            recovery: if snapshot.launch_agent_installed { None } else { Some(recovery) },
        });

        if let Some(error) = self.current_error() {
            findings.push(DiagnosticFinding {
                code: format!("last_error.{}", error.code),
                ok: false,
                recovery: Some(error.message),
            });
        }

        findings
    }

    /// 첫 번째로 일치하는 운영 문제가 복구 명령을 고른다.
    fn operational_recovery(snapshot: &StatusSnapshot) -> String {
        let model_bad = snapshot.model_revision.is_none() || !snapshot.model_valid;
        if !snapshot.launch_agent_installed || model_bad {
            return "debrief install --repair".to_string();
        }
        if matches!(snapshot.process, DaemonProcessState::Running) && !snapshot.socket_present {
            return "debrief install --repair".to_string();
        }
        if !matches!(snapshot.process, DaemonProcessState::Running) && snapshot.launch_agent_installed {
            return "debrief start".to_string();
        }
        "debrief install --repair".to_string()
    }

    /// `debrief doctor`용 실패 항목만.
    pub fn doctor_problem_lines(&self, limit: usize) -> Vec<String> {
        self.doctor().into_iter().filter(|f| !f.ok).take(limit).map(|f| f.summary_line()).collect()
    }

    /// 클립보드 복사를 위한 전체 평문 doctor 리포트.
    pub fn doctor_report_text(&self) -> String {
        let findings = self.doctor();
        let lines: Vec<String> = findings.iter().map(|f| f.summary_line()).collect();
        let mut body = format!("debrief 진단 ({})\n", crate::DebriefVersion::CURRENT);
        if lines.is_empty() {
            body.push_str("(결과 없음)");
        } else {
            body.push_str(&lines.join("\n"));
        }
        body
    }

    /// 호스트별(Claude/Codex/Grok) debrief MCP 배선 상태.
    pub fn host_mcp_statuses(&self) -> Vec<HostMcpStatus> {
        HostMcpProbe::statuses(&self.paths.home, &self.paths.executable_url)
    }

    pub fn record_error(&self, component: &str, code: &str, message: &str) -> std::io::Result<()> {
        let normalized: String = message.split_whitespace().collect::<Vec<_>>().join(" ");
        let value = CurrentError {
            timestamp: Self::now_rfc3339(),
            component: component.chars().take(64).collect(),
            code: code.chars().take(64).collect(),
            message: normalized.chars().take(CurrentError::MAXIMUM_MESSAGE_LENGTH).collect(),
        };
        let data = serde_json::to_vec_pretty(&value).expect("current error always serializes");
        AtomicInstallerFile::write(&data, &self.paths.last_error_url, 0o600)
    }

    /// 있다면 가장 최근의 유계(bounded) 에러를 읽는다.
    pub fn current_error(&self) -> Option<CurrentError> {
        let data = std::fs::read(&self.paths.last_error_url).ok()?;
        serde_json::from_slice(&data).ok()
    }

    /// 성공적인 복구(서비스 시작/훅 전달) 후 이전 에러를 제거한다.
    pub fn clear_current_error(&self) -> std::io::Result<()> {
        if self.paths.last_error_url.exists() {
            std::fs::remove_file(&self.paths.last_error_url)?;
        }
        Ok(())
    }

    pub fn live_process_exists(pid: i32) -> bool {
        // SAFETY: kill(pid, 0) sends no signal — it only probes whether the pid exists
        // and is reachable, which is why its errno (EPERM) also counts as "exists".
        unsafe { libc::kill(pid, 0) == 0 || *libc::__error() == libc::EPERM }
    }

    fn process_state(&self) -> DaemonProcessState {
        let Ok(data) = std::fs::read_to_string(&self.paths.pid_url) else {
            return DaemonProcessState::Missing;
        };
        let trimmed = data.trim();
        let Ok(pid) = trimmed.parse::<i32>() else {
            return if self.paths.pid_url.exists() { DaemonProcessState::Invalid } else { DaemonProcessState::Missing };
        };
        if pid <= 0 {
            return DaemonProcessState::Invalid;
        }
        if (self.process_exists)(pid) {
            DaemonProcessState::Running
        } else {
            DaemonProcessState::Stale
        }
    }

    fn model_state(&self) -> (Option<String>, bool) {
        let Ok(installed) = InstalledModel::resolve_current(&self.paths.models_directory, "supertonic-3") else {
            return (None, false);
        };
        let marker = installed.directory.join(".validated.json");
        let Ok(data) = std::fs::read(&marker) else { return (Some(installed.revision), false) };
        let Ok(manifest) = serde_json::from_slice::<ModelManifest>(&data) else {
            return (Some(installed.revision), false);
        };
        let valid = manifest.revision == installed.revision
            && manifest == ModelManifest::supertonic3()
            && manifest.validate().is_ok();
        (Some(installed.revision), valid)
    }

    fn settings_readable(url: &Path) -> bool {
        if !url.exists() {
            return true;
        }
        let Ok(data) = std::fs::read(url) else { return false };
        matches!(serde_json::from_slice::<serde_json::Value>(&data), Ok(serde_json::Value::Object(_)))
    }

    /// Grok 설정은 TOML이다: 파일이 없으면 ok, UTF-8로 읽히면 ok (JSON 파싱 없음).
    fn settings_readable_toml(url: &Path) -> bool {
        if !url.exists() {
            return true;
        }
        std::fs::read_to_string(url).is_ok()
    }

    /// 호스트별 doctor 코드: JSON 호스트는 invalid_json, TOML 호스트는 invalid_toml.
    fn host_settings_finding(&self, host: HostSource) -> DiagnosticFinding {
        match host {
            HostSource::Grok => DiagnosticFinding {
                code: "host.grok.invalid_toml".to_string(),
                ok: false,
                recovery: Some("repair ~/.grok/config.toml as UTF-8 TOML, then run debrief install --grok --repair".to_string()),
            },
            HostSource::Codex => {
                let hooks_ok = Self::settings_readable(&self.paths.home.join(".codex/hooks.json"));
                if !hooks_ok {
                    DiagnosticFinding {
                        code: "host.codex.invalid_json".to_string(),
                        ok: false,
                        recovery: Some("repair ~/.codex/hooks.json, then run debrief install --codex --repair".to_string()),
                    }
                } else {
                    DiagnosticFinding {
                        code: "host.codex.invalid_toml".to_string(),
                        ok: false,
                        recovery: Some(
                            "repair ~/.codex/config.toml as UTF-8 TOML, then run debrief install --codex --repair".to_string(),
                        ),
                    }
                }
            }
            HostSource::Claude => DiagnosticFinding {
                code: "host.claude.invalid_json".to_string(),
                ok: false,
                recovery: Some("repair the host JSON, then run debrief install --claude --repair".to_string()),
            },
        }
    }

    fn now_rfc3339() -> String {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        format!("{}", now.as_secs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::install_manifest::{InstallManifest, OwnedHook, OwnedInstalledFile};
    use crate::model_manifest::ModelManifest;
    use std::fs;
    use std::path::PathBuf;

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = std::env::temp_dir().join(format!("debrief-diagnostics-tests-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    fn write_json(value: &serde_json::Value, url: &Path) {
        fs::create_dir_all(url.parent().unwrap()).unwrap();
        fs::write(url, serde_json::to_vec_pretty(value).unwrap()).unwrap();
    }

    fn install_model_marker(paths: &DebriefPaths, corrupt: bool) {
        let manifest = ModelManifest::supertonic3();
        let directory = paths.models_directory.join("supertonic-3").join(&manifest.revision);
        fs::create_dir_all(&directory).unwrap();
        let marker_data = if corrupt { b"{}".to_vec() } else { serde_json::to_vec(&manifest).unwrap() };
        fs::write(directory.join(".validated.json"), marker_data).unwrap();
        write_json(
            &serde_json::json!({"revision": manifest.revision, "relativePath": manifest.revision}),
            &paths.models_directory.join("supertonic-3/current.json"),
        );
    }

    #[test]
    fn status_reports_only_current_state_for_healthy_installation() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        DebriefConfiguration { mode: DebriefMode::Focus, muted: false, ..Default::default() }.save(&paths.config_url).unwrap();
        fs::create_dir_all(paths.socket_url.parent().unwrap()).unwrap();
        fs::write(&paths.socket_url, []).unwrap();
        fs::write(&paths.pid_url, "123").unwrap();
        install_model_marker(&paths, false);
        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "plist").unwrap();
        InstallManifest {
            hooks: vec![OwnedHook {
                host: HostSource::Codex,
                event: crate::hook_event::HookEventName::Stop,
                sha256: "a".repeat(64),
            }],
            files: vec![OwnedInstalledFile { host: HostSource::Codex, path: "/missing".to_string(), sha256: "b".repeat(64) }],
            runtime_files: Vec::new(),
        }
        .save(&paths.install_manifest_url)
        .unwrap();
        write_json(&serde_json::json!({}), &home.join(".codex/hooks.json"));
        write_json(&serde_json::json!({}), &home.join(".claude/settings.json"));

        let status = Diagnostics::with_process_check(&home, |pid| pid == 123).status();

        assert_eq!(status.mode, DebriefMode::Focus);
        assert_eq!(status.process, DaemonProcessState::Running);
        assert!(status.socket_present);
        assert_eq!(status.model_revision, Some(ModelManifest::supertonic3().revision));
        assert!(status.model_valid);
        assert_eq!(status.owned_hook_count, 1);
        assert_eq!(status.owned_skill_count, 1);

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_finds_stale_process_missing_model_invalid_marker_and_unreadable_host() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.pid_url.parent().unwrap()).unwrap();
        fs::write(&paths.pid_url, "999").unwrap();
        write_json(&serde_json::json!([]), &home.join(".codex/hooks.json"));

        let findings = Diagnostics::with_process_check(&home, |_| false).doctor();
        assert!(findings.iter().any(|f| f.code == "daemon.stale_pid" && !f.ok));
        assert!(findings.iter().any(|f| f.code == "model.missing" && !f.ok));
        assert!(findings.iter().any(|f| f.code == "host.codex.invalid_json" && !f.ok));

        install_model_marker(&paths, true);
        let findings = Diagnostics::with_process_check(&home, |_| false).doctor();
        assert!(findings.iter().any(|f| f.code == "model.invalid_marker" && !f.ok));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn status_text_uses_cli_lines() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        DebriefConfiguration { mode: DebriefMode::Night, muted: true, companion_enabled: false, ..Default::default() }
            .save(&paths.config_url)
            .unwrap();
        install_model_marker(&paths, true);
        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "plist").unwrap();

        let text = Diagnostics::with_process_check(&home, |_| false).status_text();
        assert!(text.contains("프로세스: 없음"));
        assert!(text.contains("음소거: 켜짐"));
        assert!(text.contains("모드: night"));
        assert!(text.contains("도우미 음성: 꺼짐"));
        assert!(text.contains(&format!("모델: {} (사용할 수 없음)", ModelManifest::supertonic3().revision)));
        assert!(text.contains("소켓: 없음"));
        assert!(text.contains("LaunchAgent: 설치됨"));
        assert!(!text.to_lowercase().contains("menu"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_parked_daemon_suggests_repair_not_the_menu() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.pid_url.parent().unwrap()).unwrap();
        fs::write(&paths.pid_url, "123").unwrap();
        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "plist").unwrap();
        install_model_marker(&paths, false);

        let diagnostics = Diagnostics::with_process_check(&home, |pid| pid == 123);
        let findings = diagnostics.doctor();
        assert!(findings.iter().any(|f| f.code == "daemon.running" && f.ok));
        let socket = findings.iter().find(|f| f.code == "socket.missing").unwrap();
        assert!(!socket.ok);
        assert_eq!(socket.recovery, Some("debrief install --repair".to_string()));
        let report = diagnostics.doctor_report_text();
        assert!(!report.to_lowercase().contains("menu"));
        assert!(!report.contains("menubar"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_stopped_daemon_with_plist_suggests_start() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "plist").unwrap();
        install_model_marker(&paths, false);

        let findings = Diagnostics::with_process_check(&home, |_| false).doctor();
        let daemon = findings.iter().find(|f| f.code == "daemon.missing").unwrap();
        assert_eq!(daemon.recovery, Some("debrief start".to_string()));
        assert!(findings.iter().any(|f| f.code == "socket.missing" && f.recovery == Some("debrief start".to_string())));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_uses_host_aware_code_for_unreadable_grok_toml() {
        let home = temporary_home();
        let grok = home.join(".grok/config.toml");
        fs::create_dir_all(grok.parent().unwrap()).unwrap();
        fs::write(&grok, [0xFFu8, 0xFE, 0xFD]).unwrap();

        let findings = Diagnostics::with_process_check(&home, |_| false).doctor();
        assert!(findings.iter().any(|f| f.code == "mcp.grok.unreadable" && !f.ok));
        assert!(!findings.iter().any(|f| f.code == "host.grok.invalid_toml"));
        assert!(!findings.iter().any(|f| f.code == "host.grok.invalid_json"));
        let grok_finding = findings.iter().find(|f| f.code == "mcp.grok.unreadable").unwrap();
        assert!(grok_finding.recovery.is_some());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_reports_missing_claude_mcp_when_settings_exist() {
        let home = temporary_home();
        write_json(&serde_json::json!({"mcpServers": {}}), &home.join(".claude/settings.json"));

        let findings = Diagnostics::with_process_check(&home, |_| false).doctor();
        assert!(findings.iter().any(|f| f.code == "mcp.claude.missing" && !f.ok));
        let statuses = Diagnostics::new(&home).host_mcp_statuses();
        assert!(statuses.iter().any(|s| s.host == HostSource::Claude && s.state == crate::host_mcp_status::HostMcpState::Missing));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn doctor_includes_last_error_and_problem_lines() {
        let home = temporary_home();
        let diagnostics = Diagnostics::new(&home);
        diagnostics.record_error("tts", "synthesis_or_playback", "합성 실패").unwrap();
        let findings = diagnostics.doctor();
        assert!(findings.iter().any(|f| f.code == "last_error.synthesis_or_playback" && !f.ok));
        let lines = diagnostics.doctor_problem_lines(8);
        assert!(!lines.is_empty());
        assert!(lines.iter().any(|l| l.contains("synthesis_or_playback") || l.contains("합성")));
        let report = diagnostics.doctor_report_text();
        assert!(report.contains("debrief 진단"));
        assert!(report.contains("synthesis_or_playback") || report.contains("합성"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn last_error_atomically_replaces_and_bounds_non_content_message() {
        let home = temporary_home();
        let diagnostics = Diagnostics::new(&home);
        diagnostics.record_error("model", "download", &"x".repeat(400)).unwrap();
        let first = fs::read(DebriefPaths::for_home(&home).last_error_url).unwrap();
        diagnostics.record_error("daemon", "socket", "socket unavailable\nretry").unwrap();
        let second = fs::read(DebriefPaths::for_home(&home).last_error_url).unwrap();
        assert_ne!(first, second);
        let value: CurrentError = serde_json::from_slice(&second).unwrap();
        assert_eq!(value.component, "daemon");
        assert_eq!(value.message, "socket unavailable retry");
        assert!(value.message.chars().count() <= CurrentError::MAXIMUM_MESSAGE_LENGTH);
        assert_eq!(diagnostics.current_error().unwrap().code, "socket");
        diagnostics.clear_current_error().unwrap();
        assert!(diagnostics.current_error().is_none());
        assert!(!DebriefPaths::for_home(&home).last_error_url.exists());

        fs::remove_dir_all(&home).ok();
    }
}
