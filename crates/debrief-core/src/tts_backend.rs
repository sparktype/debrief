// PCM 오디오 버퍼와 TTS 백엔드가 구현해야 하는 합성 인터페이스
#[derive(Debug, Clone, PartialEq)]
pub struct PcmBuffer {
    pub sample_rate: f64,
    pub channels: usize,
    pub samples: Vec<f32>,
}

pub trait TtsBackend: Send + Sync {
    fn synthesize(&self, text: &str, voice: &str, speed: f64) -> Result<PcmBuffer, TtsBackendError>;

    /// 문장마다 합성되는 대로 `sink`에 넘긴다(문장 사이 무음 없음). `sink`가 false면 남은 문장을 버린다.
    fn synthesize_sentences(
        &self,
        text: &str,
        voice: &str,
        speed: f64,
        sink: &mut dyn FnMut(PcmBuffer) -> bool,
    ) -> Result<(), TtsBackendError> {
        sink(self.synthesize(text, voice, speed)?);
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum TtsBackendError {
    SynthesisFailed,
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Whole;
    impl TtsBackend for Whole {
        fn synthesize(&self, text: &str, _voice: &str, _speed: f64) -> Result<PcmBuffer, TtsBackendError> {
            Ok(PcmBuffer { sample_rate: 44_100.0, channels: 1, samples: vec![text.len() as f32] })
        }
    }

    #[test]
    fn default_sentence_synthesis_emits_the_whole_text_once() {
        let mut emitted = Vec::new();
        Whole
            .synthesize_sentences("ab. cd.", "F1", 1.0, &mut |buffer| {
                emitted.push(buffer.samples[0]);
                true
            })
            .unwrap();
        assert_eq!(emitted, vec![7.0]);
    }

    #[test]
    fn pcm_buffer_carries_mono_float_samples() {
        let buffer = PcmBuffer { sample_rate: 44_100.0, channels: 1, samples: vec![0.0, 0.5, -0.5] };
        assert_eq!(buffer.sample_rate, 44_100.0);
        assert_eq!(buffer.channels, 1);
        assert_eq!(buffer.samples, vec![0.0, 0.5, -0.5]);
    }
}
