// MCP speak 도구 인자 파싱·검증·UDS 제출
use crate::speech_emotion::{EmotionProsody, SpeechEmotion};
use crate::speech_envelope::SpeechEnvelope;
use crate::speech_lane::SpeechLane;
use crate::speech_request::{SpeechPriority, SpeechRequest};
use crate::voice_catalog::VoiceCatalog;
use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
pub enum CommandError {
    Usage(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct McpSpeakArguments {
    pub text: String,
    pub voice: String,
    pub speed: f64,
    pub volume: f64,
    pub priority: SpeechPriority,
    pub lane: SpeechLane,
    pub emotion: SpeechEmotion,
    /// 사용자 결정 대기 — main에서만 인정한다.
    pub decision: bool,
    /// 호스트 세션 id. 도우미 재생은 이 id에 할당된 로테이션 보이스를 쓴다.
    pub session: Option<String>,
}

impl McpSpeakArguments {
    pub fn new(text: String, voice: String, speed: f64, volume: f64) -> Self {
        McpSpeakArguments {
            text,
            voice,
            speed,
            volume,
            priority: SpeechPriority::Main,
            lane: SpeechLane::Companion,
            emotion: SpeechEmotion::Neutral,
            decision: false,
            session: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct McpToolCallResult {
    pub is_error: bool,
    pub message: String,
}

pub trait SpeechSink {
    type Error: std::fmt::Debug;
    fn submit(&self, request: SpeechRequest) -> Result<(), Self::Error>;
}

pub struct McpSpeakTool;

impl McpSpeakTool {
    pub fn parse_arguments(object: &serde_json::Map<String, Value>) -> Result<McpSpeakArguments, CommandError> {
        let text = object
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| CommandError::Usage("speak requires string text".to_string()))?
            .to_string();
        let voice = object
            .get("voice")
            .and_then(|v| v.as_str())
            .ok_or_else(|| CommandError::Usage("speak requires string voice".to_string()))?
            .to_string();
        let speed = Self::number(object.get("speed"), "speed")?;
        let volume = Self::number(object.get("volume"), "volume")?;
        let priority = Self::optional_priority(object.get("priority"))?;
        let lane = Self::optional_lane(object.get("lane"))?;
        let emotion = Self::optional_emotion(object.get("emotion"))?;
        let session = Self::optional_session(object.get("session"))?;
        let decision = Self::optional_intent(object.get("intent"))? && matches!(priority, SpeechPriority::Main);
        Ok(McpSpeakArguments { text, voice, speed, volume, priority, lane, emotion, decision, session })
    }

    pub fn execute<S: SpeechSink>(
        arguments: &McpSpeakArguments,
        sink: &S,
        diagnostics: &crate::diagnostics::Diagnostics,
        companion_voice: Option<&str>,
    ) -> McpToolCallResult {
        // work 레인은 음성 바이어스로 중립적인 어조를 선호한다 (설계 §8.3).
        let emotion_for_prosody = if matches!(arguments.lane, SpeechLane::Work) { SpeechEmotion::Neutral } else { arguments.emotion };
        let (speed, volume) = EmotionProsody::apply(emotion_for_prosody, arguments.speed, arguments.volume);
        let voice = Self::resolved_voice(arguments, companion_voice);
        let envelope = SpeechEnvelope { v: 1, text: arguments.text.clone(), voice, speed, volume };
        if envelope.validate().is_err() {
            return McpToolCallResult { is_error: true, message: "잘못된 speak 인자입니다.".to_string() };
        }
        let request = SpeechRequest {
            envelope,
            priority: arguments.priority,
            lane: arguments.lane,
            emotion: arguments.emotion,
            agent_type: None,
            decision: arguments.decision,
            cue: arguments.decision.then_some(crate::earcon::Earcon::Decision),
            replayed: false,
        };
        match sink.submit(request) {
            Ok(()) => {
                let _ = diagnostics.clear_current_error();
                McpToolCallResult { is_error: false, message: "{\"ok\":true}".to_string() }
            }
            Err(error) => {
                let message = Self::short_error(&error);
                let _ = diagnostics.record_error("mcp", "delivery_failed", &format!("mcp speak: {message}"));
                McpToolCallResult { is_error: true, message }
            }
        }
    }

    /// 도우미 레인은 세션 로테이션을 재생한다. work 레인은 요청된 역할 보이스를 유지한다.
    fn resolved_voice(arguments: &McpSpeakArguments, companion_voice: Option<&str>) -> String {
        if matches!(arguments.lane, SpeechLane::Companion) {
            if let Some(voice) = companion_voice {
                if VoiceCatalog::allowed_voice_ids().contains(voice) {
                    return voice.to_string();
                }
            }
        }
        arguments.voice.clone()
    }

    fn optional_session(value: Option<&Value>) -> Result<Option<String>, CommandError> {
        let Some(value) = value else { return Ok(None) };
        let raw = value.as_str().ok_or_else(|| CommandError::Usage("speak session must be a string".to_string()))?;
        let trimmed = raw.trim();
        Ok(if trimmed.is_empty() { None } else { Some(trimmed.to_string()) })
    }

    fn optional_intent(value: Option<&Value>) -> Result<bool, CommandError> {
        let Some(value) = value else { return Ok(false) };
        match value.as_str() {
            Some("decision") => Ok(true),
            _ => Err(CommandError::Usage("speak intent must be \"decision\"".to_string())),
        }
    }

    fn optional_priority(value: Option<&Value>) -> Result<SpeechPriority, CommandError> {
        let Some(value) = value else { return Ok(SpeechPriority::Main) };
        match value.as_str() {
            Some("main") => Ok(SpeechPriority::Main),
            Some("subagent") => Ok(SpeechPriority::Subagent),
            _ => Err(CommandError::Usage("speak priority must be \"main\" or \"subagent\"".to_string())),
        }
    }

    fn optional_lane(value: Option<&Value>) -> Result<SpeechLane, CommandError> {
        let Some(value) = value else { return Ok(SpeechLane::Companion) };
        match value.as_str() {
            Some("companion") => Ok(SpeechLane::Companion),
            Some("work") => Ok(SpeechLane::Work),
            _ => Err(CommandError::Usage("speak lane must be \"companion\" or \"work\"".to_string())),
        }
    }

    fn optional_emotion(value: Option<&Value>) -> Result<SpeechEmotion, CommandError> {
        let Some(value) = value else { return Ok(SpeechEmotion::Neutral) };
        match value.as_str() {
            Some("neutral") => Ok(SpeechEmotion::Neutral),
            Some("warm") => Ok(SpeechEmotion::Warm),
            Some("focused") => Ok(SpeechEmotion::Focused),
            Some("concerned") => Ok(SpeechEmotion::Concerned),
            Some("relieved") => Ok(SpeechEmotion::Relieved),
            Some("tired") => Ok(SpeechEmotion::Tired),
            _ => Err(CommandError::Usage(
                "speak emotion must be one of: neutral, warm, focused, concerned, relieved, tired".to_string(),
            )),
        }
    }

    fn number(value: Option<&Value>, name: &str) -> Result<f64, CommandError> {
        match value {
            Some(Value::Number(n)) => n.as_f64(),
            // 일부 호스트가 숫자 인자를 문자열로 직렬화한다.
            Some(Value::String(s)) => s.trim().parse::<f64>().ok().filter(|n| n.is_finite()),
            _ => None,
        }
        .ok_or_else(|| CommandError::Usage(format!("speak requires number {name}")))
    }

    fn short_error<E: std::fmt::Debug>(error: &E) -> String {
        format!("{error:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    #[derive(Debug)]
    enum RecordingSinkError {
        Rejected,
    }

    struct RecordingSink {
        requests: Mutex<Vec<SpeechRequest>>,
        should_fail: bool,
    }
    impl RecordingSink {
        fn new(should_fail: bool) -> Self {
            RecordingSink { requests: Mutex::new(Vec::new()), should_fail }
        }
        fn recorded(&self) -> Vec<SpeechRequest> {
            self.requests.lock().unwrap().clone()
        }
    }
    impl SpeechSink for RecordingSink {
        type Error = RecordingSinkError;
        fn submit(&self, request: SpeechRequest) -> Result<(), Self::Error> {
            if self.should_fail {
                return Err(RecordingSinkError::Rejected);
            }
            self.requests.lock().unwrap().push(request);
            Ok(())
        }
    }

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let home = std::env::temp_dir().join(format!("debrief-mcp-speak-{nanos}-{counter}"));
        fs::create_dir_all(&home).unwrap();
        home
    }

    fn obj(pairs: &[(&str, Value)]) -> serde_json::Map<String, Value> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
    }

    #[test]
    fn parse_requires_all_fields() {
        assert!(McpSpeakTool::parse_arguments(&obj(&[("text", Value::String("hi".to_string()))])).is_err());
        let args = McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("빌드를 완료했습니다.".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(0.93)),
            ("volume", serde_json::json!(0.85)),
        ]))
        .unwrap();
        assert_eq!(args.text, "빌드를 완료했습니다.");
        assert_eq!(args.voice, "F1");
        assert_eq!(args.speed, 0.93);
        assert_eq!(args.volume, 0.85);
    }

    #[test]
    fn parse_rejects_boolean_speed_and_volume() {
        assert!(McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", Value::Bool(true)),
            ("volume", serde_json::json!(0.85)),
        ]))
        .is_err());
        assert!(McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(0.93)),
            ("volume", Value::Bool(false)),
        ]))
        .is_err());
    }

    #[test]
    fn parse_accepts_numeric_strings_for_speed_and_volume() {
        let args = McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", Value::String("0.93".to_string())),
            ("volume", Value::String("0.85".to_string())),
        ]))
        .unwrap();
        assert_eq!(args.speed, 0.93);
        assert_eq!(args.volume, 0.85);
        assert!(McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", Value::String("fast".to_string())),
            ("volume", serde_json::json!(0.85)),
        ]))
        .is_err());
    }

    #[test]
    fn companion_playback_uses_the_session_voice() {
        let diagnostics = crate::diagnostics::Diagnostics::new(Path::new("/tmp/debrief-speak-unused"));
        let sink = RecordingSink::new(false);
        let arguments = McpSpeakArguments::new("안녕".to_string(), "F1".to_string(), 0.93, 0.85);
        let result = McpSpeakTool::execute(&arguments, &sink, &diagnostics, Some("M4"));
        assert!(!result.is_error);
        assert_eq!(sink.recorded().last().unwrap().envelope.voice, "M4");
    }

    #[test]
    fn work_lane_keeps_the_requested_voice() {
        let diagnostics = crate::diagnostics::Diagnostics::new(Path::new("/tmp/debrief-speak-unused"));
        let sink = RecordingSink::new(false);
        let arguments =
            McpSpeakArguments { lane: SpeechLane::Work, ..McpSpeakArguments::new("사실".to_string(), "M1".to_string(), 1.0, 0.8) };
        let result = McpSpeakTool::execute(&arguments, &sink, &diagnostics, Some("M4"));
        assert!(!result.is_error);
        assert_eq!(sink.recorded().last().unwrap().envelope.voice, "M1");
    }

    #[test]
    fn parse_reads_session() {
        let parsed = McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("안녕".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(0.93)),
            ("volume", serde_json::json!(0.85)),
            ("session", Value::String(" alpha ".to_string())),
        ]))
        .unwrap();
        assert_eq!(parsed.session, Some("alpha".to_string()));
    }

    #[test]
    fn execute_submits_valid_request() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments::new("완료했습니다.".to_string(), "F1".to_string(), 0.93, 0.85);
        let result = McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        assert!(!result.is_error);
        assert_eq!(sink.recorded().len(), 1);
        assert_eq!(sink.recorded()[0].envelope.text, "완료했습니다.");
        assert_eq!(sink.recorded()[0].priority, SpeechPriority::Main);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn parse_optional_priority_defaults_to_main() {
        let main = McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(1.0)),
            ("volume", serde_json::json!(0.5)),
        ]))
        .unwrap();
        assert_eq!(main.priority, SpeechPriority::Main);
        assert_eq!(main.lane, SpeechLane::Companion);
        assert_eq!(main.emotion, SpeechEmotion::Neutral);

        let sub = McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(1.0)),
            ("volume", serde_json::json!(0.5)),
            ("priority", Value::String("subagent".to_string())),
            ("lane", Value::String("work".to_string())),
            ("emotion", Value::String("focused".to_string())),
        ]))
        .unwrap();
        assert_eq!(sub.priority, SpeechPriority::Subagent);
        assert_eq!(sub.lane, SpeechLane::Work);
        assert_eq!(sub.emotion, SpeechEmotion::Focused);

        assert!(McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(1.0)),
            ("volume", serde_json::json!(0.5)),
            ("priority", Value::String("boss".to_string())),
        ]))
        .is_err());
        assert!(McpSpeakTool::parse_arguments(&obj(&[
            ("text", Value::String("hi".to_string())),
            ("voice", Value::String("F1".to_string())),
            ("speed", serde_json::json!(1.0)),
            ("volume", serde_json::json!(0.5)),
            ("emotion", Value::String("angry".to_string())),
        ]))
        .is_err());
    }

    #[test]
    fn execute_applies_emotion_prosody_to_envelope() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments {
            emotion: SpeechEmotion::Tired,
            ..McpSpeakArguments::new("잠시 쉬어도 됩니다.".to_string(), "F1".to_string(), 1.0, 1.0)
        };
        let result = McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        assert!(!result.is_error);
        let recorded = sink.recorded();
        let envelope = &recorded[0].envelope;
        assert_eq!(envelope.speed, 1.0);
        assert_eq!(envelope.volume, 0.75);
        assert_eq!(recorded[0].lane, SpeechLane::Companion);
        assert_eq!(recorded[0].emotion, SpeechEmotion::Tired);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn execute_rejects_bad_voice_without_submit() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments::new("x".to_string(), "BAD".to_string(), 1.0, 1.0);
        let result = McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        assert!(result.is_error);
        assert!(sink.recorded().is_empty());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn sink_failure_is_error_and_records_diagnostics() {
        let home = temporary_home();
        let diagnostics = crate::diagnostics::Diagnostics::new(&home);
        let args = McpSpeakArguments::new("x".to_string(), "F1".to_string(), 1.0, 0.5);
        let result = McpSpeakTool::execute(&args, &RecordingSink::new(true), &diagnostics, None);
        assert!(result.is_error);
        assert!(!result.message.is_empty());
        assert!(result.message.to_lowercase().contains("rejected"));
        let error = diagnostics.current_error().unwrap();
        assert_eq!(error.component, "mcp");
        assert_eq!(error.code, "delivery_failed");
        assert!(error.message.contains("mcp speak:"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn emotion_auto_is_rejected() {
        let object = serde_json::json!({"text": "x", "voice": "F1", "speed": 1.0, "volume": 1.0, "emotion": "auto"});
        assert!(McpSpeakTool::parse_arguments(object.as_object().unwrap()).is_err());
    }

    #[test]
    fn subagent_priority_is_submitted_unchanged() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments {
            priority: SpeechPriority::Subagent,
            ..McpSpeakArguments::new("사소한 사실".to_string(), "M1".to_string(), 1.0, 0.8)
        };
        McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        assert_eq!(sink.recorded()[0].priority, SpeechPriority::Subagent);
        fs::remove_dir_all(&home).ok();
    }

    fn parse(value: serde_json::Value) -> Result<McpSpeakArguments, CommandError> {
        McpSpeakTool::parse_arguments(value.as_object().unwrap())
    }

    #[test]
    fn intent_decision_marks_main_requests_only() {
        let base = serde_json::json!({"text": "x", "voice": "F1", "speed": 1.0, "volume": 1.0, "intent": "decision"});
        assert!(parse(base.clone()).unwrap().decision);
        let mut subagent = base.clone();
        subagent["priority"] = "subagent".into();
        assert!(!parse(subagent).unwrap().decision, "서브에이전트는 결정을 요청하지 않는다");
        let mut bad = base;
        bad["intent"] = "urgent".into();
        assert!(parse(bad).is_err());
    }

    #[test]
    fn decision_request_carries_decision_cue() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments { decision: true, ..McpSpeakArguments::new("결정해 주세요".to_string(), "F1".to_string(), 0.93, 0.85) };
        McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        let recorded = sink.recorded();
        assert!(recorded[0].decision);
        assert_eq!(recorded[0].cue, Some(crate::earcon::Earcon::Decision));
        fs::remove_dir_all(&home).ok();
    }
}
