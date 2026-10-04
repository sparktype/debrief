// 호스트별 훅 페이로드를 HookEvent로 정규화하고, 응답 JSON을 생성
use crate::hook_event::{HookEvent, HookEventName, HostSource};
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookAdapterError {
    InvalidJson,
    MissingEventName,
    UnsupportedEvent(String),
    MissingSessionId,
}

pub struct HookAdapter;

impl HookAdapter {
    pub fn decode(data: &[u8], source: HostSource) -> Result<HookEvent, HookAdapterError> {
        let payload: Value = serde_json::from_slice(data).map_err(|_| HookAdapterError::InvalidJson)?;
        let Value::Object(ref payload) = payload else {
            return Err(HookAdapterError::InvalidJson);
        };

        let raw_event = string_in(payload, &["hook_event_name", "hookEventName", "event_name", "eventName"])
            .ok_or(HookAdapterError::MissingEventName)?;
        let event_name = HookEventName::from_str_value(&raw_event)
            .ok_or_else(|| HookAdapterError::UnsupportedEvent(raw_event.clone()))?;

        let session_keys: &[&str] = match source {
            HostSource::Codex => &["session_id", "sessionId", "conversation_id", "conversationId"],
            HostSource::Claude | HostSource::Grok => &["session_id", "sessionId"],
        };
        let session_id = string_in(payload, session_keys)
            .filter(|value| !value.is_empty())
            .ok_or(HookAdapterError::MissingSessionId)?;

        Ok(HookEvent {
            name: event_name,
            session_id,
            turn_id: string_in(payload, &["turn_id", "turnId"]),
            agent_type: string_in(
                payload,
                &["agent_type", "agentType", "subagent_type", "subagentType", "agent_name", "agentName"],
            ),
            last_assistant_message: string_in(payload, &["last_assistant_message", "lastAssistantMessage"]),
            cwd: string_in(payload, &["cwd"]),
            subtype: string_in(payload, &["notification_type", "error_type"]),
        })
    }

    pub fn context_output(context: &str, event: &HookEvent) -> Vec<u8> {
        let output = json!({
            "hookSpecificOutput": {
                "hookEventName": event.name.as_str(),
                "additionalContext": context,
            }
        });
        serde_json::to_vec(&output).expect("context output always serializes")
    }

    pub fn success_output() -> Vec<u8> {
        b"{}".to_vec()
    }
}

fn string_in(payload: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(Value::String(value)) = payload.get(*key) {
            return Some(value.clone());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn fixture(name: &str) -> Vec<u8> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../SwiftTests/Fixtures/Hooks")
            .join(name);
        fs::read(path).unwrap()
    }

    #[test]
    fn stop_normalizes_envelope_text() {
        for source in [HostSource::Codex, HostSource::Claude] {
            let data = fixture(&format!("{}-stop.json", source.as_str()));
            let event = HookAdapter::decode(&data, source).unwrap();
            assert_eq!(event.name, HookEventName::Stop);
            assert!(event.last_assistant_message.unwrap().contains("chorus:speak"));
        }
    }

    #[test]
    fn normalizes_all_fixtures() {
        let cases = [
            (HostSource::Codex, "codex-session-start.json", HookEventName::SessionStart),
            (HostSource::Codex, "codex-user-prompt-submit.json", HookEventName::UserPromptSubmit),
            (HostSource::Codex, "codex-subagent-start.json", HookEventName::SubagentStart),
            (HostSource::Codex, "codex-stop.json", HookEventName::Stop),
            (HostSource::Codex, "codex-subagent-stop.json", HookEventName::SubagentStop),
            (HostSource::Claude, "claude-session-start.json", HookEventName::SessionStart),
            (HostSource::Claude, "claude-user-prompt-submit.json", HookEventName::UserPromptSubmit),
            (HostSource::Claude, "claude-subagent-start.json", HookEventName::SubagentStart),
            (HostSource::Claude, "claude-stop.json", HookEventName::Stop),
            (HostSource::Claude, "claude-subagent-stop.json", HookEventName::SubagentStop),
        ];
        for (source, fixture_name, expected) in cases {
            let data = fixture(fixture_name);
            let event = HookAdapter::decode(&data, source).unwrap();
            assert_eq!(event.name, expected);
            assert!(!event.session_id.is_empty());
            if matches!(expected, HookEventName::SubagentStart | HookEventName::SubagentStop) {
                assert_eq!(event.agent_type, Some("planner".to_string()));
            }
        }
    }

    #[test]
    fn context_output_uses_hook_specific_additional_context() {
        for _source in [HostSource::Codex, HostSource::Claude] {
            let event = HookEvent {
                name: HookEventName::SessionStart,
                session_id: "s".to_string(),
                turn_id: None,
                agent_type: None,
                last_assistant_message: None,
                cwd: None,
                subtype: None,
            };
            let data = HookAdapter::context_output("context", &event);
            let text = String::from_utf8(data).unwrap();
            assert!(text.contains("hookSpecificOutput"));
            assert!(text.contains("additionalContext"));
            assert!(text.contains("SessionStart"));
        }
    }

    #[test]
    fn codex_live_stop_preserves_complete_envelope_comment() {
        let data = fixture("codex-stop-live.json");
        let event = HookAdapter::decode(&data, HostSource::Codex).unwrap();
        assert_eq!(
            event.last_assistant_message.unwrap(),
            "완료.\n<!-- chorus:speak {\"v\":1,\"text\":\"Codex 보존 검증을 완료했습니다.\",\"voice\":\"F1\",\"speed\":0.93,\"volume\":0.6} -->"
        );
    }

    #[test]
    fn permission_request_carries_cwd() {
        let payload = json!({
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "cwd": "/Users/x/work/proj",
            "tool_name": "Bash",
        });
        let data = serde_json::to_vec(&payload).unwrap();
        let event = HookAdapter::decode(&data, HostSource::Claude).unwrap();
        assert_eq!(event.name, HookEventName::PermissionRequest);
        assert_eq!(event.cwd.as_deref(), Some("/Users/x/work/proj"));
    }

    #[test]
    fn claude_subagent_type_alias_maps_to_agent_type() {
        let payload = json!({
            "hook_event_name": "SubagentStart",
            "session_id": "claude-s1",
            "subagent_type": "Explore",
        });
        let data = serde_json::to_vec(&payload).unwrap();
        let event = HookAdapter::decode(&data, HostSource::Claude).unwrap();
        assert_eq!(event.name, HookEventName::SubagentStart);
        assert_eq!(event.agent_type, Some("Explore".to_string()));
    }

    #[test]
    fn decodes_claude_only_events_with_subtype() {
        let cases = [
            (json!({"hook_event_name": "StopFailure", "session_id": "s", "error_type": "rate_limit"}), HookEventName::StopFailure, Some("rate_limit")),
            (json!({"hook_event_name": "Notification", "session_id": "s", "notification_type": "idle_prompt", "message": "m"}), HookEventName::Notification, Some("idle_prompt")),
            (json!({"hook_event_name": "SessionEnd", "session_id": "s", "reason": "clear"}), HookEventName::SessionEnd, None),
            (json!({"hook_event_name": "Elicitation", "session_id": "s"}), HookEventName::Elicitation, None),
            (json!({"hook_event_name": "PermissionDenied", "session_id": "s"}), HookEventName::PermissionDenied, None),
            (json!({"hook_event_name": "TeammateIdle", "session_id": "s"}), HookEventName::TeammateIdle, None),
            (json!({"hook_event_name": "TaskCompleted", "session_id": "s"}), HookEventName::TaskCompleted, None),
        ];
        for (payload, name, subtype) in cases {
            let event = HookAdapter::decode(&serde_json::to_vec(&payload).unwrap(), HostSource::Claude).unwrap();
            assert_eq!(event.name, name);
            assert_eq!(event.subtype.as_deref(), subtype, "{name:?}");
            assert_eq!(HookEventName::from_str_value(name.as_str()), Some(name));
        }
    }
}
