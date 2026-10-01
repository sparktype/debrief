// PCM 오디오 버퍼와 TTS 백엔드가 구현해야 하는 합성 인터페이스
#[derive(Debug, Clone, PartialEq)]
pub struct PcmBuffer {
    pub sample_rate: f64,
    pub channels: usize,
    pub samples: Vec<f32>,
}

pub trait TtsBackend: Send + Sync {
    fn synthesize(&self, text: &str, voice: &str, speed: f64) -> Result<PcmBuffer, TtsBackendError>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum TtsBackendError {
    SynthesisFailed,
}
