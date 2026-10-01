// 큐 승인·모드 정책에 쓰이는 발화 우선순위와 요청 구조체
use crate::speech_emotion::SpeechEmotion;
use crate::speech_envelope::SpeechEnvelope;
use crate::speech_lane::SpeechLane;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpeechPriority {
    Main,
    Subagent,
}

impl SpeechPriority {
    pub fn as_str(&self) -> &'static str {
        match self {
            SpeechPriority::Main => "main",
            SpeechPriority::Subagent => "subagent",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SpeechRequest {
    pub envelope: SpeechEnvelope,
    pub priority: SpeechPriority,
    pub lane: SpeechLane,
    pub emotion: SpeechEmotion,
    pub agent_type: Option<String>,
}

impl SpeechRequest {
    pub fn is_main(&self) -> bool {
        matches!(self.priority, SpeechPriority::Main)
    }
}
