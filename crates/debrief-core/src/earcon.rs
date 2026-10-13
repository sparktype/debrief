// 결정·주의·실패·완료를 알리는 짧은 사인파 효과음을 코드로 만든다
use crate::tts_backend::PcmBuffer;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Earcon {
    Decision,
    Attention,
    Failure,
    Done,
}

impl Earcon {
    pub const SAMPLE_RATE: f64 = 44_100.0;
    const FADE_SECONDS: f64 = 0.010;

    pub fn as_str(&self) -> &'static str {
        match self {
            Earcon::Decision => "decision",
            Earcon::Attention => "attention",
            Earcon::Failure => "failure",
            Earcon::Done => "done",
        }
    }

    pub fn from_str_value(value: &str) -> Option<Earcon> {
        match value {
            "decision" => Some(Earcon::Decision),
            "attention" => Some(Earcon::Attention),
            "failure" => Some(Earcon::Failure),
            "done" => Some(Earcon::Done),
            _ => None,
        }
    }

    /// (주파수 Hz, 길이 초) 순서열과 진폭. 완료음은 약하게 낸다.
    fn shape(&self) -> (&'static [(f64, f64)], f64) {
        match self {
            Earcon::Decision => (&[(660.0, 0.12), (880.0, 0.12)], 0.5),
            Earcon::Attention => (&[(740.0, 0.15)], 0.5),
            Earcon::Failure => (&[(587.0, 0.14), (440.0, 0.14)], 0.5),
            Earcon::Done => (&[(523.0, 0.10)], 0.3),
        }
    }

    pub fn buffer(&self) -> PcmBuffer {
        let (tones, amplitude) = self.shape();
        let fade = (Self::FADE_SECONDS * Self::SAMPLE_RATE) as usize;
        let mut samples = Vec::new();
        for &(frequency, seconds) in tones {
            let count = (seconds * Self::SAMPLE_RATE).round() as usize;
            for index in 0..count {
                // 톤마다 앞뒤를 선형 페이드해 클릭음을 막는다.
                let envelope = (index.min(count - 1 - index) as f64 / fade as f64).min(1.0);
                let phase = 2.0 * std::f64::consts::PI * frequency * index as f64 / Self::SAMPLE_RATE;
                samples.push((amplitude * envelope * phase.sin()) as f32);
            }
        }
        PcmBuffer { sample_rate: Self::SAMPLE_RATE, channels: 1, samples }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for earcon in [Earcon::Decision, Earcon::Attention, Earcon::Failure, Earcon::Done] {
            assert_eq!(Earcon::from_str_value(earcon.as_str()), Some(earcon));
        }
        assert_eq!(Earcon::from_str_value("beep"), None);
    }

    #[test]
    fn buffers_have_expected_length_and_shape() {
        let cases = [(Earcon::Decision, 5292 * 2), (Earcon::Attention, 6615), (Earcon::Failure, 6174 * 2), (Earcon::Done, 4410)];
        for (earcon, count) in cases {
            let buffer = earcon.buffer();
            assert_eq!(buffer.sample_rate, 44_100.0);
            assert_eq!(buffer.channels, 1);
            assert_eq!(buffer.samples.len(), count, "{earcon:?}");
            assert!(buffer.samples.first().unwrap().abs() < 1e-3, "{earcon:?} 시작 클릭");
            assert!(buffer.samples.last().unwrap().abs() < 1e-3, "{earcon:?} 끝 클릭");
            assert!(buffer.samples.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
            assert!(buffer.samples.iter().any(|s| s.abs() > 0.1), "{earcon:?} 무음");
        }
    }
}
