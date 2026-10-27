// `debrief hook --source <host>`가 쓰는 훅 실행기 — stdin 페이로드를 받아 stdout(JSON)을 돌려준다
use crate::configuration::DebriefConfiguration;
use crate::hook_adapter::HookAdapter;
use crate::hook_engine::HookEngine;
use crate::hook_event::{HookEventName, HostSource};
use crate::paths::DebriefPaths;
use crate::session_state::SessionStateStore;
use crate::session_voice_rotation::SessionVoiceStore;
use crate::unix_socket::UnixSocketClient;

pub struct HookCommandRunner;

impl HookCommandRunner {
    const UNREACHABLE_COOLDOWN_SECONDS: u64 = 600;
    const UNREACHABLE_MESSAGE: &'static str =
        "debrief 데몬에 연결할 수 없어 음성 브리핑이 나오지 않습니다. `debrief restart`로 다시 띄우세요.";

    pub fn run(input: &[u8], source: HostSource, home: &std::path::Path) -> Vec<u8> {
        let Ok(event) = HookAdapter::decode(input, source) else {
            return b"{}".to_vec();
        };
        let paths = DebriefPaths::for_home(home);
        let session_voices = SessionVoiceStore::new(paths.session_voices_url.clone());
        // 방해금지로 올라간 유효 모드를 쓰고, 올라갔는지는 저장된 모드와 비교해 안다.
        let stored = DebriefConfiguration::load(&paths.config_url);
        let configuration = DebriefConfiguration::load_effective(&paths.config_url, home);
        let dnd_raised = configuration.mode != stored.mode;
        let session_state = SessionStateStore::new(paths.session_state_url.clone());
        let muted = configuration.muted;
        let engine = HookEngine::new(Some(&session_voices)).with_state(&session_state, configuration).with_dnd_raised(dnd_raised);
        let mut result = engine.handle(&event, source);
        let mut daemon_reachable = None;
        if let Some(control) = result.control.take() {
            // 데몬이 꺼져 있으면 끊을 것도 없다 — 알림 실패 기록을 덮지 않게 결과를 무시한다.
            let sent = UnixSocketClient::new(paths.socket_url.clone()).send_control(&control);
            daemon_reachable = Some(!matches!(sent, Err(crate::unix_socket::UnixSocketError::SystemCall(..))));
        }
        let prompt_event = matches!(event.name, HookEventName::SessionStart | HookEventName::UserPromptSubmit);
        if prompt_event && matches!(source, HostSource::Claude | HostSource::Codex) && !muted {
            let reachable =
                daemon_reachable.unwrap_or_else(|| UnixSocketClient::new(paths.socket_url.clone()).is_reachable());
            let now = crate::session_state::now_seconds();
            let warn = !reachable
                && session_state
                    .update(now, |states| {
                        states.allow_notice(&event.session_id, "daemon_unreachable", now, Self::UNREACHABLE_COOLDOWN_SECONDS)
                    })
                    .unwrap_or(false);
            if warn {
                result.stdout = HookAdapter::with_output_field(&result.stdout, "systemMessage", Self::UNREACHABLE_MESSAGE);
            }
        }
        if let Some(notice) = result.notice.take() {
            match UnixSocketClient::new(paths.socket_url.clone()).submit(&notice) {
                Ok(()) => result.submitted = true,
                Err(error) => result.delivery_error = Some(format!("{error:?}")),
            }
        }
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
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hooks").join(name);
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

    #[test]
    fn permission_request_reaches_the_daemon_socket() {
        let home = temporary_home();
        let socket_url = DebriefPaths::for_home(&home).socket_url;
        let server = std::sync::Arc::new(crate::unix_socket::UnixSocketServer::new(socket_url).unwrap());
        let accepting = server.clone();
        let received = std::thread::spawn(move || accepting.accept());

        let payload = br#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/w/debrief","tool_name":"Bash"}"#;
        let output = HookCommandRunner::run(payload, HostSource::Claude, &home);

        assert_eq!(String::from_utf8(output).unwrap(), "{}");
        let crate::daemon_control::Inbound::Speech(request) = received.join().unwrap().unwrap() else { panic!("발화가 아님") };
        assert_eq!(request.envelope.text, "권한 승인을 기다리고 있습니다.");
        assert_eq!(request.lane, crate::speech_lane::SpeechLane::Work);
        assert!(crate::diagnostics::Diagnostics::new(&home).current_error().is_none());

        fs::remove_dir_all(&home).ok();
    }

    fn system_message(output: &[u8]) -> Option<String> {
        let value: serde_json::Value = serde_json::from_slice(output).unwrap();
        value["systemMessage"].as_str().map(str::to_string)
    }

    #[test]
    fn unreachable_daemon_is_shown_once_per_cooldown_on_prompt_events() {
        let home = temporary_home();
        let start = br#"{"hook_event_name":"SessionStart","session_id":"s"}"#;
        let prompt = br#"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#;

        let first = HookCommandRunner::run(start, HostSource::Claude, &home);
        assert!(system_message(&first).unwrap().contains("debrief restart"));
        assert!(system_message(&HookCommandRunner::run(prompt, HostSource::Claude, &home)).is_none(), "쿨다운 안");
        let other = br#"{"hook_event_name":"UserPromptSubmit","session_id":"other"}"#;
        assert!(system_message(&HookCommandRunner::run(other, HostSource::Codex, &home)).is_some(), "세션마다 따로");
        let gemini = br#"{"hook_event_name":"SessionStart","session_id":"g"}"#;
        assert!(system_message(&HookCommandRunner::run(gemini, HostSource::Gemini, &home)).is_none());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn reachable_or_muted_daemon_adds_no_system_message() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        let start = br#"{"hook_event_name":"SessionStart","session_id":"s"}"#;

        let muted = DebriefConfiguration { muted: true, ..DebriefConfiguration::default() };
        muted.save(&paths.config_url).unwrap();
        assert!(system_message(&HookCommandRunner::run(start, HostSource::Claude, &home)).is_none(), "음소거면 침묵이 의도");
        DebriefConfiguration::default().save(&paths.config_url).unwrap();

        let server = std::sync::Arc::new(crate::unix_socket::UnixSocketServer::new(paths.socket_url).unwrap());
        let accepting = server.clone();
        let probe = std::thread::spawn(move || accepting.accept());
        let output = HookCommandRunner::run(start, HostSource::Claude, &home);
        assert!(system_message(&output).is_none(), "{}", String::from_utf8_lossy(&output));
        let probed = probe.join().unwrap().unwrap_err();
        assert!(crate::unix_socket::is_recoverable_accept_error(&probed), "빈 연결은 데몬을 멈추지 않는다: {probed:?}");

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn notice_without_daemon_still_succeeds_and_records_the_failure() {
        let home = temporary_home();
        let payload = br#"{"hook_event_name":"PermissionRequest","session_id":"s"}"#;

        let output = HookCommandRunner::run(payload, HostSource::Codex, &home);

        assert_eq!(String::from_utf8(output).unwrap(), "{}");
        assert!(crate::diagnostics::Diagnostics::new(&home).current_error().is_some());

        fs::remove_dir_all(&home).ok();
    }
}
