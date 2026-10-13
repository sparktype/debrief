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
    /// 속도는 요청값 그대로 둔다(청취 실험: 감정별 속도 변화보다 모델 기본 속도가 자연스러웠다). 볼륨만 바꾼다.
    pub fn apply(emotion: SpeechEmotion, speed: f64, volume: f64) -> (f64, f64) {
        let volume_factor = match emotion {
            SpeechEmotion::Concerned => 1.05,
            SpeechEmotion::Tired => 0.75,
            SpeechEmotion::Neutral | SpeechEmotion::Warm | SpeechEmotion::Focused | SpeechEmotion::Relieved => 1.0,
        };
        (speed.clamp(0.7, 2.0), (volume * volume_factor).clamp(0.0, 1.0))
    }

    /// 문장 사이 무음 길이(초). 청취 실험에서 고른 값이며 neutral은 기존 고정값 0.3초.
    pub fn pause_seconds(emotion: SpeechEmotion) -> f64 {
        match emotion {
            SpeechEmotion::Focused => 0.1,
            SpeechEmotion::Neutral => 0.3,
            SpeechEmotion::Relieved => 0.55,
            SpeechEmotion::Warm => 0.7,
            SpeechEmotion::Concerned => 0.8,
            SpeechEmotion::Tired => 1.1,
        }
    }

    /// Supertonic 3 표현 태그. 청취 실험에서 `<laugh>`만 또렷했고 `<sigh>`·`<breath>`는 약했다.
    pub fn expression_tag(emotion: SpeechEmotion) -> Option<&'static str> {
        match emotion {
            SpeechEmotion::Relieved => Some("<laugh>"),
            SpeechEmotion::Warm => Some("<breath>"),
            SpeechEmotion::Tired => Some("<sigh>"),
            SpeechEmotion::Neutral | SpeechEmotion::Focused | SpeechEmotion::Concerned => None,
        }
    }

    /// 합성할 텍스트: 에이전트가 넣은 `<` `>`는 지워 태그 주입을 막고, 감정 태그만 맨 앞에 붙인다.
    pub fn spoken_text(emotion: SpeechEmotion, text: &str) -> String {
        let sanitized: String = text.chars().filter(|c| *c != '<' && *c != '>').collect();
        match Self::expression_tag(emotion) {
            Some(tag) => format!("{tag} {sanitized}"),
            None => sanitized,
        }
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
    fn tired_softens_without_changing_speed() {
        let (speed, volume) = EmotionProsody::apply(SpeechEmotion::Tired, 1.05, 1.0);
        assert_eq!(speed, 1.05);
        assert_eq!(volume, 0.75);
    }

    #[test]
    fn no_emotion_changes_the_requested_speed() {
        use SpeechEmotion::*;
        for emotion in [Neutral, Warm, Focused, Concerned, Relieved, Tired] {
            assert_eq!(EmotionProsody::apply(emotion, 1.05, 0.8).0, 1.05);
        }
    }

    #[test]
    fn sentence_pauses_follow_the_listening_test_values() {
        use SpeechEmotion::*;
        let pauses: Vec<f64> = [Focused, Neutral, Relieved, Warm, Concerned, Tired].map(EmotionProsody::pause_seconds).to_vec();
        assert_eq!(pauses, vec![0.1, 0.3, 0.55, 0.7, 0.8, 1.1]);
    }

    #[test]
    fn expression_tags_follow_the_listening_test_mapping() {
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Relieved), Some("<laugh>"));
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Warm), Some("<breath>"));
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Tired), Some("<sigh>"));
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Concerned), None);
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Neutral), None);
        assert_eq!(EmotionProsody::expression_tag(SpeechEmotion::Focused), None);
    }

    #[test]
    fn spoken_text_strips_agent_angle_brackets_and_prepends_the_tag() {
        assert_eq!(EmotionProsody::spoken_text(SpeechEmotion::Neutral, "a <laugh> b"), "a laugh b");
        assert_eq!(EmotionProsody::spoken_text(SpeechEmotion::Relieved, "끝났습니다."), "<laugh> 끝났습니다.");
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
