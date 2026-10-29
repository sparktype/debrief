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
        let event_name = HookEventName::from_native(&raw_event, source)
            .ok_or_else(|| HookAdapterError::UnsupportedEvent(raw_event.clone()))?;

        let session_keys: &[&str] = match source {
            HostSource::Codex => &["session_id", "sessionId", "conversation_id", "conversationId"],
            HostSource::Claude | HostSource::Grok | HostSource::Gemini => &["session_id", "sessionId"],
        };
        let session_id = string_in(payload, session_keys)
            .filter(|value| !value.is_empty())
            .ok_or(HookAdapterError::MissingSessionId)?;

        // SessionEnd의 `reason`은 세션 종료 사유라 알림 종류로 쓰지 않는다. StopCancelled만 취소 사유다.
        let mut subtype = string_in(payload, &["notification_type", "error_type", "trigger"]);
        if event_name == HookEventName::StopCancelled {
            subtype = string_in(payload, &["reason"]).or(subtype);
        }

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
            subtype,
            stop_hook_active: ["stop_hook_active", "stopHookActive"]
                .iter()
                .any(|key| payload.get(*key).and_then(Value::as_bool) == Some(true)),
        })
    }

    pub fn context_output(context: &str, event: &HookEvent, source: HostSource) -> Vec<u8> {
        let output = json!({
            "hookSpecificOutput": {
                "hookEventName": event.name.native_name(source),
                "additionalContext": context,
            }
        });
        serde_json::to_vec(&output).expect("context output always serializes")
    }

    /// 훅 출력 JSON 객체에 최상위 필드(`systemMessage`·`terminalSequence` 등)를 더한다.
    pub fn with_output_field(output: &[u8], key: &str, value: &str) -> Vec<u8> {
        let mut object = match serde_json::from_slice::<Value>(output) {
            Ok(Value::Object(object)) => object,
            _ => serde_json::Map::new(),
        };
        object.insert(key.to_string(), Value::String(value.to_string()));
        serde_json::to_vec(&Value::Object(object)).expect("hook output always serializes")
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
            .join("tests/fixtures/hooks")
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
                stop_hook_active: false,
            };
            let data = HookAdapter::context_output("context", &event, HostSource::Claude);
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
    fn decodes_gemini_native_events_and_echoes_their_names() {
        let cases = [
            (json!({"hook_event_name": "SessionStart", "session_id": "g", "source": "startup"}), HookEventName::SessionStart, None),
            (json!({"hook_event_name": "BeforeAgent", "session_id": "g", "prompt": "p"}), HookEventName::UserPromptSubmit, None),
            (json!({"hook_event_name": "AfterAgent", "session_id": "g", "prompt_response": "r"}), HookEventName::Stop, None),
            (json!({"hook_event_name": "Notification", "session_id": "g", "notification_type": "ToolPermission"}), HookEventName::PermissionRequest, Some("ToolPermission")),
            (json!({"hook_event_name": "PreCompress", "session_id": "g", "trigger": "auto"}), HookEventName::PreCompact, Some("auto")),
            (json!({"hook_event_name": "SessionEnd", "session_id": "g", "reason": "exit"}), HookEventName::SessionEnd, None),
        ];
        for (payload, name, subtype) in cases {
            let native = payload["hook_event_name"].as_str().unwrap().to_string();
            let event = HookAdapter::decode(&serde_json::to_vec(&payload).unwrap(), HostSource::Gemini).unwrap();
            assert_eq!(event.name, name);
            assert_eq!(event.subtype.as_deref(), subtype, "{native}");
            assert_eq!(name.native_name(HostSource::Gemini), native);
        }
        let unsupported = json!({"hook_event_name": "UserPromptSubmit", "session_id": "g"});
        assert!(HookAdapter::decode(&serde_json::to_vec(&unsupported).unwrap(), HostSource::Gemini).is_err());

        let event = HookAdapter::decode(br#"{"hook_event_name":"BeforeAgent","session_id":"g"}"#, HostSource::Gemini).unwrap();
        let output: serde_json::Value = serde_json::from_slice(&HookAdapter::context_output("c", &event, HostSource::Gemini)).unwrap();
        assert_eq!(output["hookSpecificOutput"]["hookEventName"], "BeforeAgent");
        assert_eq!(output["hookSpecificOutput"]["additionalContext"], "c");
    }

    #[test]
    fn stop_hook_active_flag_is_decoded() {
        let active = HookAdapter::decode(br#"{"hook_event_name":"Stop","session_id":"s","stop_hook_active":true}"#, HostSource::Codex).unwrap();
        assert!(active.stop_hook_active);
        let plain = HookAdapter::decode(br#"{"hook_event_name":"Stop","session_id":"s"}"#, HostSource::Claude).unwrap();
        assert!(!plain.stop_hook_active);
    }

    #[test]
    fn decodes_codex_compaction_and_interrupt() {
        let cases = [
            (json!({"hook_event_name": "PreCompact", "session_id": "c", "trigger": "auto"}), HookEventName::PreCompact, Some("auto")),
            (json!({"hook_event_name": "PostCompact", "session_id": "c", "trigger": "manual"}), HookEventName::PostCompact, Some("manual")),
            (json!({"hook_event_name": "Interrupt", "session_id": "c", "turn_id": "t1"}), HookEventName::Interrupt, None),
        ];
        for (payload, name, subtype) in cases {
            let event = HookAdapter::decode(&serde_json::to_vec(&payload).unwrap(), HostSource::Codex).unwrap();
            assert_eq!(event.name, name);
            assert_eq!(event.subtype.as_deref(), subtype, "{name:?}");
            assert_eq!(HookEventName::from_str_value(name.as_str()), Some(name));
        }
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
            (json!({"hook_event_name": "PreCompact", "session_id": "s", "trigger": "auto"}), HookEventName::PreCompact, Some("auto")),
            (json!({"hook_event_name": "PostCompact", "session_id": "s", "trigger": "manual"}), HookEventName::PostCompact, Some("manual")),
        ];
        for (payload, name, subtype) in cases {
            let event = HookAdapter::decode(&serde_json::to_vec(&payload).unwrap(), HostSource::Claude).unwrap();
            assert_eq!(event.name, name);
            assert_eq!(event.subtype.as_deref(), subtype, "{name:?}");
            assert_eq!(HookEventName::from_str_value(name.as_str()), Some(name));
        }
    }
}
