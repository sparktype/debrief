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
    StopFailure,
    SessionEnd,
    Notification,
    Elicitation,
    PermissionDenied,
    TeammateIdle,
    TaskCompleted,
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
            HookEventName::StopFailure => "StopFailure",
            HookEventName::SessionEnd => "SessionEnd",
            HookEventName::Notification => "Notification",
            HookEventName::Elicitation => "Elicitation",
            HookEventName::PermissionDenied => "PermissionDenied",
            HookEventName::TeammateIdle => "TeammateIdle",
            HookEventName::TaskCompleted => "TaskCompleted",
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
            "StopFailure" => Some(HookEventName::StopFailure),
            "SessionEnd" => Some(HookEventName::SessionEnd),
            "Notification" => Some(HookEventName::Notification),
            "Elicitation" => Some(HookEventName::Elicitation),
            "PermissionDenied" => Some(HookEventName::PermissionDenied),
            "TeammateIdle" => Some(HookEventName::TeammateIdle),
            "TaskCompleted" => Some(HookEventName::TaskCompleted),
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
    /// 알림 유형(`notification_type`) 또는 오류 유형(`error_type`). 이벤트에 없으면 `None`.
    pub subtype: Option<String>,
}
