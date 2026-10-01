// 오디오 재생 인터페이스 — 실제 백엔드(cpal)는 별도 계획에서 포팅한다
use crate::tts_backend::PcmBuffer;

#[derive(Debug, PartialEq, Eq)]
pub enum AudioPlayerError {
    InvalidBuffer,
    PlaybackFailed,
}

pub trait AudioPlaying: Send + Sync {
    fn play(&self, buffer: &PcmBuffer, gain: f64) -> Result<(), AudioPlayerError>;
    fn stop(&self);
}
