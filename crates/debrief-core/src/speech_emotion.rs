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
        Self::styled_text(emotion, text, false, false)
    }

    /// `spoken_text`에 청취 실험 옵션을 더한다. 둘 다 `<` `>`를 지운 뒤에 적용하므로 태그 주입 방어는 그대로다.
    /// `punctuation`: relieved·warm 문장 끝 `.`→`!!`, `?`→`?!`. `whisper`: 문장마다 `<whisper>`를 감정 태그 앞에 붙인다.
    pub fn styled_text(emotion: SpeechEmotion, text: &str, punctuation: bool, whisper: bool) -> String {
        let sanitized: String = text.chars().filter(|c| *c != '<' && *c != '>').collect();
        if !punctuation && !whisper {
            return match Self::expression_tag(emotion) {
                Some(tag) => format!("{tag} {sanitized}"),
                None => sanitized,
            };
        }
        let livelier = punctuation && matches!(emotion, SpeechEmotion::Relieved | SpeechEmotion::Warm);
        let mut sentences = Self::sentences(&sanitized);
        if livelier {
            for sentence in &mut sentences {
                if let Some(stem) = sentence.strip_suffix('.').filter(|stem| !stem.ends_with('.')) {
                    *sentence = format!("{stem}!!");
                } else if let Some(stem) = sentence.strip_suffix('?').filter(|stem| !stem.ends_with('?')) {
                    *sentence = format!("{stem}?!");
                }
            }
        }
        let tag = Self::expression_tag(emotion);
        sentences
            .iter()
            .enumerate()
            .map(|(index, sentence)| {
                let mut parts: Vec<&str> = Vec::new();
                if whisper {
                    parts.push("<whisper>");
                }
                if let Some(tag) = tag.filter(|_| index == 0) {
                    parts.push(tag);
                }
                parts.push(sentence);
                parts.join(" ")
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// `.` `!` `?` 뒤 공백에서 문장을 자른다(약어 예외 없음, 실험 옵션용).
    fn sentences(text: &str) -> Vec<String> {
        let mut sentences = vec![String::new()];
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            sentences.last_mut().unwrap().push(c);
            if matches!(c, '.' | '!' | '?') && chars.peek().is_some_and(|n| n.is_whitespace()) {
                while chars.next_if(|n| n.is_whitespace()).is_some() {}
                sentences.push(String::new());
            }
        }
        sentences.retain(|s| !s.trim().is_empty());
        sentences
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
    fn prosody_punctuation_only_changes_relieved_and_warm_sentence_ends() {
        let on = |emotion, text| EmotionProsody::styled_text(emotion, text, true, false);
        assert_eq!(on(SpeechEmotion::Relieved, "끝났습니다. 괜찮을까요?"), "<laugh> 끝났습니다!! 괜찮을까요?!");
        assert_eq!(on(SpeechEmotion::Warm, "Done. Ok?"), "<breath> Done!! Ok?!");
        assert_eq!(on(SpeechEmotion::Warm, "Wow! Hmm..."), "<breath> Wow! Hmm...");
        assert_eq!(on(SpeechEmotion::Neutral, "끝났습니다."), "끝났습니다.");
        assert_eq!(on(SpeechEmotion::Tired, "끝났습니다."), "<sigh> 끝났습니다.");
        assert_eq!(on(SpeechEmotion::Relieved, "a <b>."), "<laugh> a b!!");
        assert_eq!(EmotionProsody::styled_text(SpeechEmotion::Relieved, "끝났습니다.", false, false), "<laugh> 끝났습니다.");
    }

    #[test]
    fn night_whisper_prefixes_every_sentence_before_the_emotion_tag() {
        let whisper = |emotion, text| EmotionProsody::styled_text(emotion, text, false, true);
        assert_eq!(whisper(SpeechEmotion::Neutral, "하나. 둘."), "<whisper> 하나. <whisper> 둘.");
        assert_eq!(whisper(SpeechEmotion::Warm, "하나. 둘."), "<whisper> <breath> 하나. <whisper> 둘.");
        assert_eq!(whisper(SpeechEmotion::Neutral, "<whisper>x."), "<whisper> whisperx.");
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
