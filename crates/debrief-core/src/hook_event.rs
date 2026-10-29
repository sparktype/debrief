// 호스트 종류·훅 이벤트 이름과 정규화된 훅 이벤트 구조체
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HostSource {
    Codex,
    Claude,
    Grok,
    Gemini,
}

impl HostSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            HostSource::Codex => "codex",
            HostSource::Claude => "claude",
            HostSource::Grok => "grok",
            HostSource::Gemini => "gemini",
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
    PreCompact,
    PostCompact,
    /// Codex 전용: 사용자가 메인 스레드의 진행 중 턴을 중단했다.
    Interrupt,
    /// Grok: 진행 중 턴이 취소됐다. `user_interrupt`만 그 세션 브리핑을 끊는다.
    StopCancelled,
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
            HookEventName::PreCompact => "PreCompact",
            HookEventName::PostCompact => "PostCompact",
            HookEventName::Interrupt => "Interrupt",
            HookEventName::StopCancelled => "StopCancelled",
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
            "PreCompact" => Some(HookEventName::PreCompact),
            "PostCompact" => Some(HookEventName::PostCompact),
            "Interrupt" => Some(HookEventName::Interrupt),
            "StopCancelled" => Some(HookEventName::StopCancelled),
            _ => None,
        }
    }

    /// Gemini CLI가 같은 순간을 부르는 이름(`BeforeAgent` 등). 다른 호스트는 내부 이름 그대로다.
    pub fn native_name(&self, host: HostSource) -> &'static str {
        match (host, self) {
            (HostSource::Gemini, HookEventName::UserPromptSubmit) => "BeforeAgent",
            (HostSource::Gemini, HookEventName::Stop) => "AfterAgent",
            (HostSource::Gemini, HookEventName::PermissionRequest) => "Notification",
            (HostSource::Gemini, HookEventName::PreCompact) => "PreCompress",
            _ => self.as_str(),
        }
    }

    pub fn from_native(value: &str, host: HostSource) -> Option<Self> {
        if host != HostSource::Gemini {
            return Self::from_str_value(value);
        }
        // Gemini의 Notification은 도구 권한 요청(ToolPermission)만 문서화되어 있다.
        match value {
            "SessionStart" => Some(HookEventName::SessionStart),
            "BeforeAgent" => Some(HookEventName::UserPromptSubmit),
            "AfterAgent" => Some(HookEventName::Stop),
            "Notification" => Some(HookEventName::PermissionRequest),
            "PreCompress" => Some(HookEventName::PreCompact),
            "SessionEnd" => Some(HookEventName::SessionEnd),
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
    /// Stop 훅이 이미 한 번 턴을 이어 가게 한 뒤의 Stop인지(호스트의 무한 반복 방지 신호).
    pub stop_hook_active: bool,
}
