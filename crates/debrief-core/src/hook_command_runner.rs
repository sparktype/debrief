// `debrief hook --source <host>`가 쓰는 훅 실행기 — stdin 페이로드를 받아 stdout(JSON)을 돌려준다
use crate::hook_adapter::HookAdapter;
use crate::hook_engine::HookEngine;
use crate::hook_event::HostSource;
use crate::paths::DebriefPaths;
use crate::session_voice_rotation::SessionVoiceStore;

pub struct HookCommandRunner;

impl HookCommandRunner {
    pub fn run(input: &[u8], source: HostSource, home: &std::path::Path) -> Vec<u8> {
        let Ok(event) = HookAdapter::decode(input, source) else {
            return b"{}".to_vec();
        };
        let paths = DebriefPaths::for_home(home);
        let session_voices = SessionVoiceStore::new(paths.session_voices_url.clone());
        let engine = HookEngine::new(Some(&session_voices));
        let result = engine.handle(&event, source);
        let diagnostics = crate::diagnostics::Diagnostics::new(home);
        if result.submitted {
            let _ = diagnostics.clear_current_error();
        } else if let Some(delivery_error) = &result.delivery_error {
            let _ = diagnostics.record_error(
                "hook",
                if result.submitted { "ok" } else { "delivery_failed" },
                &format!("{} {}: {delivery_error}", source.as_str(), event.name.as_str()),
            );
        }
        result.stdout
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = PathBuf::from("/tmp").join(format!("ch-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    fn fixture(name: &str) -> Vec<u8> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../SwiftTests/Fixtures/Hooks").join(name);
        fs::read(path).unwrap()
    }

    #[test]
    fn stop_with_legacy_envelope_returns_success_without_socket_traffic() {
        let home = temporary_home();
        let input = fixture("codex-stop.json");

        let output = HookCommandRunner::run(&input, HostSource::Codex, &home);

        assert_eq!(String::from_utf8(output).unwrap(), "{}");
        assert!(crate::diagnostics::Diagnostics::new(&home).current_error().is_none());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn unavailable_socket_still_returns_host_success_without_diagnostic() {
        let home = temporary_home();
        let output = HookCommandRunner::run(&fixture("claude-stop.json"), HostSource::Claude, &home);

        assert_eq!(String::from_utf8(output).unwrap(), "{}");
        assert!(crate::diagnostics::Diagnostics::new(&home).current_error().is_none());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn legacy_envelope_on_stop_is_ignored_without_diagnostic() {
        let home = temporary_home();
        let payload = br#"{"hook_event_name":"Stop","session_id":"s","last_assistant_message":"x\n<!-- chorus:speak {\"v\":1,\"text\":\"t\",\"voice\":\"M2\",\"speed\":1,\"volume\":0.8} -->"}"#;
        let output = HookCommandRunner::run(payload, HostSource::Claude, &home);
        assert_eq!(String::from_utf8(output).unwrap(), "{}");
        assert!(crate::diagnostics::Diagnostics::new(&home).current_error().is_none());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn session_start_context_mentions_speak_not_html_envelope() {
        let home = temporary_home();
        let payload = br#"{"hook_event_name":"SessionStart","session_id":"s","agent_type":"planner"}"#;
        let output = HookCommandRunner::run(payload, HostSource::Claude, &home);
        let text = String::from_utf8(output).unwrap();
        assert!(text.contains("speak"));
        assert!(text.contains("M1"));
        assert!(!text.contains("chorus:speak"));
        assert!(!text.contains("<!--"));

        fs::remove_dir_all(&home).ok();
    }
}
