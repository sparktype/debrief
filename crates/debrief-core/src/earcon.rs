// 결정·주의·실패·완료를 알리는 짧은 벨 음색 효과음을 코드로 만든다
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
    /// 무선 이어폰이 깨어나며 첫 소리를 먹는 경우를 위한 앞 무음.
    const LEAD_IN_SECONDS: f64 = 0.08;
    /// 음 사이 간격. 연속 음이 한 음으로 뭉치지 않게 한다(Handbook 14장 Table 14.2: 0.1초 이상).
    const GAP_SECONDS: f64 = 0.10;
    /// 기본음에 더하는 배음의 상대 진폭(1배음부터). 순수 사인파보다 이어폰에서 잘 들린다.
    const HARMONICS: [f64; 3] = [1.0, 0.5, 0.25];
    /// 음마다 소리가 줄어드는 정도. 클수록 짧게 울린다.
    const DECAY_PER_SECOND: f64 = 8.0;

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

    /// (기본 주파수 Hz, 길이 초) 순서열과 진폭. 종류마다 음 수·길이(리듬)를 다르게 한다.
    fn shape(&self) -> (&'static [(f64, f64)], f64) {
        match self {
            // 결정: 2음 상승, 길게 — 눈에 띄어야 한다.
            Earcon::Decision => (&[(660.0, 0.30), (880.0, 0.40)], 0.6),
            // 주의: 한 음, 가운데 높이.
            Earcon::Attention => (&[(740.0, 0.36)], 0.6),
            // 실패: 3음 하강, 낮게 끝난다.
            Earcon::Failure => (&[(587.0, 0.22), (494.0, 0.22), (370.0, 0.40)], 0.6),
            // 완료: 짧은 2음 상승. 가장 약하지만 이어폰에서 들릴 만큼은 낸다.
            Earcon::Done => (&[(523.0, 0.18), (784.0, 0.30)], 0.5),
        }
    }

    pub fn buffer(&self) -> PcmBuffer {
        let (tones, amplitude) = self.shape();
        let fade = (Self::FADE_SECONDS * Self::SAMPLE_RATE) as usize;
        // 배음 진폭의 합으로 나눠 최대치가 amplitude를 넘지 않게 한다.
        let harmonic_sum: f64 = Self::HARMONICS.iter().sum();
        let mut samples = vec![0.0; (Self::LEAD_IN_SECONDS * Self::SAMPLE_RATE).round() as usize];
        for (position, &(frequency, seconds)) in tones.iter().enumerate() {
            if position > 0 {
                samples.extend(std::iter::repeat_n(0.0, (Self::GAP_SECONDS * Self::SAMPLE_RATE).round() as usize));
            }
            let count = (seconds * Self::SAMPLE_RATE).round() as usize;
            for index in 0..count {
                let time = index as f64 / Self::SAMPLE_RATE;
                // 앞뒤 선형 페이드로 클릭음을 막고, 지수 감쇠로 벨처럼 울리다 사라지게 한다.
                let fades = (index.min(count - 1 - index) as f64 / fade as f64).min(1.0);
                let envelope = fades * (-Self::DECAY_PER_SECOND * time).exp();
                let tone: f64 = Self::HARMONICS
                    .iter()
                    .enumerate()
                    .map(|(n, weight)| weight * (2.0 * std::f64::consts::PI * frequency * (n + 1) as f64 * time).sin())
                    .sum();
                samples.push((amplitude * envelope * tone / harmonic_sum) as f32);
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
        // 앞 무음 3528 + 음 길이 합 + 음 사이 간격 4410 × (음 수 − 1).
        let cases = [(Earcon::Decision, 38_808), (Earcon::Attention, 19_404), (Earcon::Failure, 49_392), (Earcon::Done, 29_106)];
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

    const ALL: [Earcon; 4] = [Earcon::Decision, Earcon::Attention, Earcon::Failure, Earcon::Done];

    // The Sonification Handbook 14장 Table 14.2: 음정은 125Hz~5kHz, 모티프는 4음 이하.
    #[test]
    fn notes_and_harmonics_stay_in_the_audible_range() {
        for earcon in ALL {
            let (tones, _) = earcon.shape();
            assert!(tones.len() <= 4, "{earcon:?} 음이 너무 많음");
            for &(frequency, _) in tones {
                assert!(frequency >= 125.0, "{earcon:?} 너무 낮음");
                assert!(frequency * Earcon::HARMONICS.len() as f64 <= 5_000.0, "{earcon:?} 배음이 5kHz 초과");
            }
        }
    }

    // 같은 사인파 음높이만으로 구분하지 않는다 — 리듬(음 수·길이)이 서로 달라야 한다.
    #[test]
    fn rhythms_are_pairwise_distinct() {
        for (i, a) in ALL.iter().enumerate() {
            for b in &ALL[i + 1..] {
                let rhythm = |e: &Earcon| e.shape().0.iter().map(|&(_, seconds)| (seconds * 1000.0).round() as u32).collect::<Vec<_>>();
                assert_ne!(rhythm(a), rhythm(b), "{a:?} / {b:?} 리듬 동일");
            }
        }
    }

    // 순수 사인파가 아니라 배음이 섞여야 한다(음색). 기본음 주파수의 2배음 성분이 있어야 함.
    #[test]
    fn timbre_contains_the_second_harmonic() {
        let buffer = Earcon::Done.buffer();
        let (tones, _) = Earcon::Done.shape();
        let frequency = tones[0].0;
        let lead = (Earcon::LEAD_IN_SECONDS * Earcon::SAMPLE_RATE) as usize;
        let power_at = |f: f64| {
            let (mut re, mut im) = (0.0, 0.0);
            for (n, &s) in buffer.samples[lead..].iter().enumerate() {
                let phase = 2.0 * std::f64::consts::PI * f * n as f64 / Earcon::SAMPLE_RATE;
                re += s as f64 * phase.cos();
                im += s as f64 * phase.sin();
            }
            re * re + im * im
        };
        assert!(power_at(2.0 * frequency) > 0.02 * power_at(frequency), "2배음 없음");
    }

    // 이어폰이 첫 소리를 먹는 경우를 위해 효과음 앞에 무음을 둔다.
    #[test]
    fn starts_with_silence_for_wireless_wake_up() {
        let lead = (Earcon::LEAD_IN_SECONDS * Earcon::SAMPLE_RATE) as usize;
        for earcon in ALL {
            let buffer = earcon.buffer();
            assert!(buffer.samples[..lead].iter().all(|s| *s == 0.0), "{earcon:?}");
            assert!(buffer.samples[lead..].iter().any(|s| s.abs() > 0.1), "{earcon:?}");
        }
    }
}
