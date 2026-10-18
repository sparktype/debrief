// 데몬 소켓으로 들어오는 제어 명령(끊기·비우기·다시 듣기)과 수신 항목 구분
use crate::speech_request::SpeechRequest;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Control {
    Skip,
    SkipAll,
    /// 이 세션의 companion 브리핑(결정 대기 제외)을 재생 중이든 대기 중이든 버린다.
    SkipSession(String),
    /// 최근 기록 n개(1..=10)를 오래된 순으로 다시 재생한다.
    Replay(u8),
}

impl Control {
    pub const MAXIMUM_REPLAY: u8 = 10;
}

#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    Speech(SpeechRequest),
    Control(Control),
}
