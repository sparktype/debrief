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
    /// 사용자 결정 대기 — ModePolicy가 상한·companion off·subagent 억제를 건너뛴다(mute는 아님).
    pub decision: bool,
    /// 발화 직전에 낼 효과음.
    pub cue: Option<crate::earcon::Earcon>,
    /// 데몬 내부 표시: replay로 다시 넣은 요청은 기록에 쌓지 않는다. 프레임에 실리지 않는다.
    pub replayed: bool,
}

impl SpeechRequest {
    pub fn is_main(&self) -> bool {
        matches!(self.priority, SpeechPriority::Main)
    }

    /// 텍스트 없이 효과음만 내는 요청(훅 전용).
    pub fn is_cue_only(&self) -> bool {
        self.envelope.text.is_empty() && self.cue.is_some()
    }
}
