// 호스트 종류·훅 이벤트 이름과 정규화된 훅 이벤트 구조체
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HostSource {
    Codex,
    Claude,
    Grok,
}

impl HostSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            HostSource::Codex => "codex",
            HostSource::Claude => "claude",
            HostSource::Grok => "grok",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HookEventName {
    SessionStart,
    UserPromptSubmit,
    SubagentStart,
    Stop,
    SubagentStop,
    PermissionRequest,
}

impl HookEventName {
    pub fn as_str(&self) -> &'static str {
        match self {
            HookEventName::SessionStart => "SessionStart",
            HookEventName::UserPromptSubmit => "UserPromptSubmit",
            HookEventName::SubagentStart => "SubagentStart",
            HookEventName::Stop => "Stop",
            HookEventName::SubagentStop => "SubagentStop",
            HookEventName::PermissionRequest => "PermissionRequest",
        }
    }

    pub fn from_str_value(value: &str) -> Option<Self> {
        match value {
            "SessionStart" => Some(HookEventName::SessionStart),
            "UserPromptSubmit" => Some(HookEventName::UserPromptSubmit),
            "SubagentStart" => Some(HookEventName::SubagentStart),
            "Stop" => Some(HookEventName::Stop),
            "SubagentStop" => Some(HookEventName::SubagentStop),
            "PermissionRequest" => Some(HookEventName::PermissionRequest),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookEvent {
    pub name: HookEventName,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub agent_type: Option<String>,
    pub last_assistant_message: Option<String>,
    pub cwd: Option<String>,
}
