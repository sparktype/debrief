// 훅 이벤트를 호스트에 돌려줄 stdout(JSON)으로 변환 — speak 계약은 MCP speak 도구로 이동했으므로
// 이 엔진은 더 이상 직접 발화를 전송하지 않는다(Swift 원본의 `sink` 매개변수에 대응하는
// 전송 경로는 제거했다 — 호출되지 않는 코드를 유지할 이유가 없다).
use crate::hook_adapter::HookAdapter;
use crate::hook_event::{HookEvent, HookEventName, HostSource};
use crate::session_voice_rotation::SessionVoiceStore;
use crate::voice_catalog::VoiceCatalog;

pub struct HookResult {
    pub stdout: Vec<u8>,
    pub submitted: bool,
    pub delivery_error: Option<String>,
}

pub struct HookEngine<'a> {
    session_voices: Option<&'a SessionVoiceStore>,
}

impl<'a> HookEngine<'a> {
    pub fn new(session_voices: Option<&'a SessionVoiceStore>) -> Self {
        HookEngine { session_voices }
    }

    pub fn handle(&self, event: &HookEvent, source: HostSource) -> HookResult {
        match event.name {
            HookEventName::SessionStart | HookEventName::UserPromptSubmit | HookEventName::SubagentStart => {
                // 서브에이전트는 역할 보이스를 유지하고 세션 로테이션의 슬롯을 차지하지 않는다.
                let session_voice = if matches!(event.name, HookEventName::SubagentStart) {
                    None
                } else {
                    self.session_voices.and_then(|store| store.claim(&event.session_id).ok())
                };
                let context = VoiceCatalog::context(event, source, session_voice.as_deref());
                let stdout = HookAdapter::context_output(&context, event);
                HookResult { stdout, submitted: false, delivery_error: None }
            }
            HookEventName::Stop | HookEventName::SubagentStop => {
                HookResult { stdout: HookAdapter::success_output(), submitted: false, delivery_error: None }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook_event::HookEventName;

    fn event(
        name: HookEventName,
        session_id: &str,
        turn_id: Option<&str>,
        agent_type: Option<&str>,
        last_assistant_message: Option<&str>,
    ) -> HookEvent {
        HookEvent {
            name,
            session_id: session_id.to_string(),
            turn_id: turn_id.map(|s| s.to_string()),
            agent_type: agent_type.map(|s| s.to_string()),
            last_assistant_message: last_assistant_message.map(|s| s.to_string()),
        }
    }

    #[test]
    fn subagent_context_uses_assigned_voice() {
        let event = event(HookEventName::SubagentStart, "s", Some("t"), Some("planner"), None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        let text = String::from_utf8(result.stdout).unwrap();
        assert!(text.contains("M1"));
        assert!(text.contains("subagent"));
        assert!(text.contains("mcp__debrief__speak") || text.contains("speak"));
        assert!(!result.submitted);
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn session_start_uses_host_agent_type_when_present() {
        let event = event(HookEventName::SessionStart, "s", None, Some("Explore"), None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        let text = String::from_utf8(result.stdout).unwrap();
        assert!(text.contains("F3"));
        assert!(text.contains("제인"));
        assert!(!result.submitted);
    }

    #[test]
    fn session_voices_rotate_and_subagents_do_not_take_a_slot() {
        let url = std::env::temp_dir().join(format!(
            "debrief-hook-voices-{}.json",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _cleanup = Cleanup(url.clone());

        let store = SessionVoiceStore::new(url);
        let engine = HookEngine::new(Some(&store));

        let text = |result: HookResult| String::from_utf8(result.stdout).unwrap();

        let first = engine.handle(&event(HookEventName::SessionStart, "alpha", None, None, None), HostSource::Claude);
        let second = engine.handle(&event(HookEventName::SessionStart, "beta", None, None, None), HostSource::Claude);
        let again =
            engine.handle(&event(HookEventName::UserPromptSubmit, "alpha", Some("t"), None, None), HostSource::Claude);
        let subagent = engine.handle(
            &event(HookEventName::SubagentStart, "child", None, Some("planner"), None),
            HostSource::Claude,
        );

        assert!(text(first).contains("F1 (연아)"));
        assert!(text(second).contains("F2 (마리)"));
        assert!(text(again).contains("F1 (연아)"));
        let subagent_text = text(subagent);
        assert!(subagent_text.contains("M1"));
        assert!(!subagent_text.contains("session="));
        assert_eq!(store.claim("gamma").unwrap(), "F3");
    }

    #[test]
    fn user_prompt_submit_defaults_to_main_voice_without_agent_type() {
        let event = event(HookEventName::UserPromptSubmit, "s", None, None, None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(String::from_utf8(result.stdout).unwrap().contains("F1"));
    }

    #[test]
    fn stop_does_not_submit_even_with_legacy_envelope() {
        let event = event(
            HookEventName::Stop,
            "s",
            None,
            None,
            Some("<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"F1\",\"speed\":0.93,\"volume\":0.85} -->"),
        );
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn subagent_stop_does_not_submit_even_with_legacy_envelope() {
        let event = event(
            HookEventName::SubagentStop,
            "s",
            Some("t"),
            Some("planner"),
            Some("<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"M1\",\"speed\":1.1,\"volume\":0.85} -->"),
        );
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn stop_without_message_is_successful_no_op() {
        let event = event(HookEventName::Stop, "s", None, None, Some("visible only"));
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert!(result.delivery_error.is_none());
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
    }
}
