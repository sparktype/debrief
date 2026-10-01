// 도우미 발화의 절제된 감정 상태(닫힌 enum)와 속도/볼륨 바이어스
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SpeechEmotion {
    Neutral,
    Warm,
    Focused,
    Concerned,
    Relieved,
    Tired,
}

pub struct EmotionProsody;

impl EmotionProsody {
    pub fn apply(emotion: SpeechEmotion, speed: f64, volume: f64) -> (f64, f64) {
        let (speed_factor, volume_factor) = match emotion {
            SpeechEmotion::Neutral => (1.0, 1.0),
            SpeechEmotion::Warm => (0.97, 1.0),
            SpeechEmotion::Focused => (1.02, 1.0),
            SpeechEmotion::Concerned => (0.95, 1.05),
            SpeechEmotion::Relieved => (0.98, 1.0),
            SpeechEmotion::Tired => (0.92, 0.90),
        };
        let biased_speed = (speed * speed_factor).clamp(0.7, 2.0);
        let biased_volume = (volume * volume_factor).clamp(0.0, 1.0);
        (biased_speed, biased_volume)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_leaves_values() {
        let (speed, volume) = EmotionProsody::apply(SpeechEmotion::Neutral, 1.0, 0.8);
        assert_eq!(speed, 1.0);
        assert_eq!(volume, 0.8);
    }

    #[test]
    fn tired_slows_and_softens() {
        let (speed, volume) = EmotionProsody::apply(SpeechEmotion::Tired, 1.0, 1.0);
        assert_eq!(speed, 0.92);
        assert_eq!(volume, 0.90);
    }

    #[test]
    fn clamps_to_legal_ranges() {
        let (high_speed, _) = EmotionProsody::apply(SpeechEmotion::Focused, 2.0, 1.0);
        assert_eq!(high_speed, 2.0);
        let (low_speed, low_volume) = EmotionProsody::apply(SpeechEmotion::Tired, 0.7, 0.0);
        assert_eq!(low_speed, 0.7);
        assert_eq!(low_volume, 0.0);
    }
}
