// MCP speak 도구 입력 봉투와 검증 규칙
use crate::voice_catalog::VoiceCatalog;
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvelopeError {
    UnsupportedVersion,
    InvalidText,
    InvalidVoice,
    InvalidSpeed,
    InvalidVolume,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SpeechEnvelope {
    pub v: i64,
    pub text: String,
    pub voice: String,
    pub speed: f64,
    pub volume: f64,
}

impl SpeechEnvelope {
    pub fn validate(&self) -> Result<(), EnvelopeError> {
        self.validate_with_voices(VoiceCatalog::allowed_voice_ids())
    }

    pub fn validate_with_voices(&self, allowed_voices: &HashSet<String>) -> Result<(), EnvelopeError> {
        if self.v != 1 {
            return Err(EnvelopeError::UnsupportedVersion);
        }
        if self.text.is_empty() || self.text.chars().count() > 800 || self.text.contains("-->") {
            return Err(EnvelopeError::InvalidText);
        }
        if self.text.chars().any(|c| c.is_control() && c != '\n') {
            return Err(EnvelopeError::InvalidText);
        }
        if !allowed_voices.contains(&self.voice) {
            return Err(EnvelopeError::InvalidVoice);
        }
        if !self.speed.is_finite() || !(0.7..=2.0).contains(&self.speed) {
            return Err(EnvelopeError::InvalidSpeed);
        }
        if !self.volume.is_finite() || !(0.0..=1.0).contains(&self.volume) {
            return Err(EnvelopeError::InvalidVolume);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unsafe_text_and_numbers() {
        let envelope = SpeechEnvelope {
            v: 1,
            text: "가".repeat(801),
            voice: "F1".to_string(),
            speed: 1.0,
            volume: 1.0,
        };
        assert_eq!(envelope.validate(), Err(EnvelopeError::InvalidText));

        let envelope = SpeechEnvelope {
            v: 1,
            text: "bad\ttext".to_string(),
            voice: "F1".to_string(),
            speed: 1.0,
            volume: 1.0,
        };
        assert_eq!(envelope.validate(), Err(EnvelopeError::InvalidText));

        let envelope = SpeechEnvelope {
            v: 1,
            text: "x".to_string(),
            voice: "F1".to_string(),
            speed: f64::NAN,
            volume: 1.0,
        };
        assert_eq!(envelope.validate(), Err(EnvelopeError::InvalidSpeed));

        let envelope = SpeechEnvelope {
            v: 1,
            text: "x".to_string(),
            voice: "F1".to_string(),
            speed: 1.0,
            volume: f64::INFINITY,
        };
        assert_eq!(envelope.validate(), Err(EnvelopeError::InvalidVolume));
    }
}
