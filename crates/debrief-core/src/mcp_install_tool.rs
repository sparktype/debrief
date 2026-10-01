// MCP install 도구 — 호스트 MCP/훅 등록·복구 (Claude/Codex/Grok)
use crate::hook_event::HostSource;
use crate::host_installer::HostInstallResult;
use crate::mcp_speak_tool::CommandError;
use serde_json::Value;
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpInstallArguments {
    /// 빈 집합은 모든 호스트를 뜻한다 (호스트 플래그 없는 CLI와 동일).
    pub hosts: HashSet<HostSource>,
    pub repair: bool,
}

/// MCP `install`을 위한 주입 가능한 설치기 (테스트는 실제 모델 다운로드를 피한다).
pub trait McpInstallRunning {
    type Error: std::fmt::Debug;
    fn install(&self, hosts: &HashSet<HostSource>, repair: bool) -> Result<HostInstallResult, Self::Error>;
}

/// 실제 `RuntimeInstaller`를 감싸는 `McpInstallRunning` 구현 — MCP `install` 도구의 기본 실행기.
pub struct LiveMcpInstallRunner {
    home: std::path::PathBuf,
    source_executable: std::path::PathBuf,
}

impl LiveMcpInstallRunner {
    pub fn new(home: std::path::PathBuf, source_executable: std::path::PathBuf) -> Self {
        LiveMcpInstallRunner { home, source_executable }
    }
}

impl McpInstallRunning for LiveMcpInstallRunner {
    type Error = crate::runtime_installer::RuntimeInstallerError;

    fn install(&self, hosts: &HashSet<HostSource>, repair: bool) -> Result<HostInstallResult, Self::Error> {
        let paths = crate::paths::DebriefPaths::for_home(&self.home);
        let model_installer = crate::model_installer::ModelInstaller::new(
            paths.models_directory.clone(),
            crate::model_manifest::ModelManifest::supertonic3(),
            crate::model_installer::UreqModelDownloader::new(),
        );
        let launchctl = crate::launch_agent_control::ProcessLaunchctlRunner::new();
        let runtime = crate::runtime_installer::RuntimeInstaller::new(
            self.home.clone(),
            self.source_executable.clone(),
            model_installer,
            &launchctl,
            // SAFETY: getuid() takes no arguments and cannot fail.
            unsafe { libc::getuid() },
        );
        runtime.install(hosts, repair)
    }
}

pub struct McpInstallTool;

impl McpInstallTool {
    pub fn parse_arguments(object: &serde_json::Map<String, Value>) -> Result<McpInstallArguments, CommandError> {
        let repair = match object.get("repair") {
            None => true,
            Some(Value::Bool(b)) => *b,
            _ => return Err(CommandError::Usage("install repair must be a boolean".to_string())),
        };

        let hosts = match object.get("hosts") {
            None => [HostSource::Codex, HostSource::Claude, HostSource::Grok].into_iter().collect(),
            Some(Value::Array(list)) => {
                let mut parsed = HashSet::new();
                for raw in list {
                    let raw = raw.as_str().ok_or_else(|| CommandError::Usage("install hosts must be an array of host names".to_string()))?;
                    let host = Self::parse_host(raw)?;
                    parsed.insert(host);
                }
                if parsed.is_empty() {
                    return Err(CommandError::Usage("install hosts must not be empty".to_string()));
                }
                parsed
            }
            Some(Value::String(single)) => [Self::parse_host(single)?].into_iter().collect(),
            _ => return Err(CommandError::Usage("install hosts must be an array of host names".to_string())),
        };

        Ok(McpInstallArguments { hosts, repair })
    }

    fn parse_host(raw: &str) -> Result<HostSource, CommandError> {
        match raw {
            "codex" => Ok(HostSource::Codex),
            "claude" => Ok(HostSource::Claude),
            "grok" => Ok(HostSource::Grok),
            other => Err(CommandError::Usage(format!("install hosts entries must be codex, claude, or grok (got {other})"))),
        }
    }

    pub fn execute<R: McpInstallRunning>(
        arguments: &McpInstallArguments,
        runner: &R,
        diagnostics: &crate::diagnostics::Diagnostics,
    ) -> crate::mcp_speak_tool::McpToolCallResult {
        match runner.install(&arguments.hosts, arguments.repair) {
            Ok(result) => {
                let _ = diagnostics.clear_current_error();
                let mut hosts: Vec<&str> = arguments.hosts.iter().map(|h| h.as_str()).collect();
                hosts.sort();
                let mut payload = serde_json::json!({
                    "ok": true,
                    "hosts": hosts,
                    "repair": arguments.repair,
                    "codexReviewRequired": result.codex_review_required,
                });
                if !result.preserved_modified_files.is_empty() {
                    payload["preserved"] = serde_json::json!(result.preserved_modified_files);
                }
                let message = serde_json::to_string(&payload).expect("install result always serializes");
                crate::mcp_speak_tool::McpToolCallResult { is_error: false, message }
            }
            Err(error) => {
                let short = format!("{error:?}");
                let _ = diagnostics.record_error("mcp", "install_failed", &format!("mcp install: {short}"));
                crate::mcp_speak_tool::McpToolCallResult {
                    is_error: true,
                    message: format!("설치에 실패했습니다: {}", short.chars().take(120).collect::<String>()),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::Mutex;

    struct FakeInstallRunner {
        should_fail: bool,
        last_hosts: Mutex<Option<HashSet<HostSource>>>,
        last_repair: Mutex<Option<bool>>,
    }
    impl FakeInstallRunner {
        fn new(should_fail: bool) -> Self {
            FakeInstallRunner { should_fail, last_hosts: Mutex::new(None), last_repair: Mutex::new(None) }
        }
    }
    impl McpInstallRunning for FakeInstallRunner {
        type Error = CommandError;
        fn install(&self, hosts: &HashSet<HostSource>, repair: bool) -> Result<HostInstallResult, Self::Error> {
            *self.last_hosts.lock().unwrap() = Some(hosts.clone());
            *self.last_repair.lock().unwrap() = Some(repair);
            if self.should_fail {
                return Err(CommandError::Usage("forced failure".to_string()));
            }
            Ok(HostInstallResult { codex_review_required: hosts.contains(&HostSource::Codex), preserved_modified_files: Vec::new() })
        }
    }

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let home = std::env::temp_dir().join(format!("debrief-mcp-install-{nanos}-{counter}"));
        fs::create_dir_all(&home).unwrap();
        home
    }

    fn obj(pairs: &[(&str, Value)]) -> serde_json::Map<String, Value> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
    }

    #[test]
    fn parse_defaults_to_all_hosts_and_repair() {
        let args = McpInstallTool::parse_arguments(&serde_json::Map::new()).unwrap();
        assert_eq!(args.hosts, [HostSource::Codex, HostSource::Claude, HostSource::Grok].into_iter().collect());
        assert!(args.repair);
    }

    #[test]
    fn parse_hosts_and_repair_flags() {
        let args = McpInstallTool::parse_arguments(&obj(&[
            ("hosts", serde_json::json!(["claude", "codex"])),
            ("repair", Value::Bool(false)),
        ]))
        .unwrap();
        assert_eq!(args.hosts, [HostSource::Claude, HostSource::Codex].into_iter().collect());
        assert!(!args.repair);
    }

    #[test]
    fn parse_rejects_unknown_host() {
        assert!(McpInstallTool::parse_arguments(&obj(&[("hosts", serde_json::json!(["claude", "windsurf"]))])).is_err());
    }

    #[test]
    fn execute_invokes_runner_and_clears_error() {
        let home = temporary_home();
        let diagnostics = crate::diagnostics::Diagnostics::new(&home);
        diagnostics.record_error("mcp", "old", "stale").unwrap();
        let runner = FakeInstallRunner::new(false);
        let result = McpInstallTool::execute(
            &McpInstallArguments { hosts: [HostSource::Claude].into_iter().collect(), repair: true },
            &runner,
            &diagnostics,
        );
        assert!(!result.is_error);
        assert!(result.message.contains("\"ok\":true"));
        assert!(result.message.contains("claude"));
        assert_eq!(runner.last_hosts.lock().unwrap().clone(), Some([HostSource::Claude].into_iter().collect()));
        assert_eq!(*runner.last_repair.lock().unwrap(), Some(true));
        assert!(diagnostics.current_error().is_none());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn execute_records_failure() {
        let home = temporary_home();
        let diagnostics = crate::diagnostics::Diagnostics::new(&home);
        let result = McpInstallTool::execute(
            &McpInstallArguments { hosts: [HostSource::Claude].into_iter().collect(), repair: true },
            &FakeInstallRunner::new(true),
            &diagnostics,
        );
        assert!(result.is_error);
        assert_eq!(diagnostics.current_error().unwrap().code, "install_failed");
        fs::remove_dir_all(&home).ok();
    }
}
