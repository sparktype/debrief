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
    /// `emotion: "auto"` 요청 — decide로 emotion을 고르고, 불가하면 `emotion`(기본 Neutral) 사용.
    pub emotion_auto: bool,
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
            emotion_auto: false,
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
        let (emotion, emotion_auto) = Self::optional_emotion(object.get("emotion"))?;
        let session = Self::optional_session(object.get("session"))?;
        Ok(McpSpeakArguments { text, voice, speed, volume, priority, lane, emotion, emotion_auto, session })
    }

    pub fn execute<S: SpeechSink>(
        arguments: &McpSpeakArguments,
        sink: &S,
        diagnostics: &crate::diagnostics::Diagnostics,
        companion_voice: Option<&str>,
    ) -> McpToolCallResult {
        Self::execute_with_decide(arguments, sink, diagnostics, companion_voice, &crate::decide_client::NoopDecideClient)
    }

    /// `execute`와 동일하지만 `decide`로 침묵 판단(아이디어 1) · emotion auto(아이디어 2) ·
    /// subagent 승격(아이디어 3)을 보강한다. `decide`가 불가하면 전부 기존 동작으로 폴백한다.
    pub fn execute_with_decide<S: SpeechSink>(
        arguments: &McpSpeakArguments,
        sink: &S,
        diagnostics: &crate::diagnostics::Diagnostics,
        companion_voice: Option<&str>,
        decide: &dyn crate::decide_client::DecideJudge,
    ) -> McpToolCallResult {
        let is_main_companion_briefing = matches!(arguments.priority, SpeechPriority::Main) && matches!(arguments.lane, SpeechLane::Companion);
        if is_main_companion_briefing {
            if let Some(score) = decide.noul(&arguments.text, "이 턴 브리핑을 사용자에게 지금 들려줄 가치가 있는가?") {
                if score < 0.5 {
                    return McpToolCallResult { is_error: false, message: "{\"ok\":true,\"skipped\":\"silence\"}".to_string() };
                }
            }
        }

        let emotion = if arguments.emotion_auto {
            decide
                .choice(
                    &arguments.text,
                    "이 발화에 가장 적합한 감정 바이어스를 고른다.",
                    &["neutral", "warm", "focused", "concerned", "relieved", "tired"],
                )
                .and_then(|choice| Self::parse_emotion(&choice))
                .unwrap_or(SpeechEmotion::Neutral)
        } else {
            arguments.emotion
        };

        let priority = if matches!(arguments.priority, SpeechPriority::Subagent) {
            match decide.choice(&arguments.text, "이 사실을 메인 턴 브리핑으로 승격할지 결정한다.", &["keep_subagent", "promote_main"]) {
                Some(ref choice) if choice == "promote_main" => SpeechPriority::Main,
                _ => SpeechPriority::Subagent,
            }
        } else {
            arguments.priority
        };

        // work 레인은 음성 바이어스로 중립적인 어조를 선호한다 (설계 §8.3).
        let emotion_for_prosody = if matches!(arguments.lane, SpeechLane::Work) { SpeechEmotion::Neutral } else { emotion };
        let (speed, volume) = EmotionProsody::apply(emotion_for_prosody, arguments.speed, arguments.volume);
        let voice = Self::resolved_voice(arguments, companion_voice);
        let envelope = SpeechEnvelope { v: 1, text: arguments.text.clone(), voice, speed, volume };
        if envelope.validate().is_err() {
            return McpToolCallResult { is_error: true, message: "잘못된 speak 인자입니다.".to_string() };
        }
        let request = SpeechRequest { envelope, priority, lane: arguments.lane, emotion, agent_type: None };
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

    fn parse_emotion(value: &str) -> Option<SpeechEmotion> {
        match value {
            "neutral" => Some(SpeechEmotion::Neutral),
            "warm" => Some(SpeechEmotion::Warm),
            "focused" => Some(SpeechEmotion::Focused),
            "concerned" => Some(SpeechEmotion::Concerned),
            "relieved" => Some(SpeechEmotion::Relieved),
            "tired" => Some(SpeechEmotion::Tired),
            _ => None,
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

    /// `(emotion, emotion_auto)`를 돌려준다. `"auto"`는 `emotion_auto=true`와 기본 `Neutral`을 돌려주고,
    /// 실제 적용될 emotion은 `execute_with_decide`가 `decide`로 결정한다.
    fn optional_emotion(value: Option<&Value>) -> Result<(SpeechEmotion, bool), CommandError> {
        let Some(value) = value else { return Ok((SpeechEmotion::Neutral, false)) };
        match value.as_str() {
            Some("neutral") => Ok((SpeechEmotion::Neutral, false)),
            Some("warm") => Ok((SpeechEmotion::Warm, false)),
            Some("focused") => Ok((SpeechEmotion::Focused, false)),
            Some("concerned") => Ok((SpeechEmotion::Concerned, false)),
            Some("relieved") => Ok((SpeechEmotion::Relieved, false)),
            Some("tired") => Ok((SpeechEmotion::Tired, false)),
            Some("auto") => Ok((SpeechEmotion::Neutral, true)),
            _ => Err(CommandError::Usage(
                "speak emotion must be one of: neutral, warm, focused, concerned, relieved, tired, auto".to_string(),
            )),
        }
    }

    fn number(value: Option<&Value>, name: &str) -> Result<f64, CommandError> {
        match value {
            Some(Value::Number(n)) => n.as_f64().ok_or_else(|| CommandError::Usage(format!("speak requires number {name}"))),
            Some(Value::Bool(_)) | None => Err(CommandError::Usage(format!("speak requires number {name}"))),
            _ => Err(CommandError::Usage(format!("speak requires number {name}"))),
        }
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
        assert_eq!(envelope.speed, 0.92);
        assert_eq!(envelope.volume, 0.90);
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

    struct StubDecide {
        noul: Option<f64>,
        choice: Option<String>,
    }
    impl crate::decide_client::DecideJudge for StubDecide {
        fn noul(&self, _state: &str, _instructions: &str) -> Option<f64> {
            self.noul
        }
        fn choice(&self, _state: &str, _instructions: &str, _options: &[&str]) -> Option<String> {
            self.choice.clone()
        }
    }

    #[test]
    fn main_companion_speech_is_silenced_when_decide_scores_it_low() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.1), choice: None };
        let args = McpSpeakArguments::new("별 내용 없음".to_string(), "F1".to_string(), 0.93, 0.85);
        let result = McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert!(!result.is_error);
        assert!(sink.recorded().is_empty());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn main_companion_speech_still_submits_when_decide_scores_it_high() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.9), choice: None };
        let args = McpSpeakArguments::new("중요한 변경 사항".to_string(), "F1".to_string(), 0.93, 0.85);
        let result = McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert!(!result.is_error);
        assert_eq!(sink.recorded().len(), 1);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn main_companion_speech_submits_when_decide_is_unavailable() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: None, choice: None };
        let args = McpSpeakArguments::new("decide 없이도 전달".to_string(), "F1".to_string(), 0.93, 0.85);
        let result = McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert!(!result.is_error);
        assert_eq!(sink.recorded().len(), 1);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn silence_gate_never_applies_to_work_lane_or_subagent_priority() {
        let home = temporary_home();
        let decide = StubDecide { noul: Some(0.0), choice: None };

        let sink = RecordingSink::new(false);
        let work_args = McpSpeakArguments {
            lane: SpeechLane::Work,
            ..McpSpeakArguments::new("사실".to_string(), "M1".to_string(), 1.0, 0.8)
        };
        McpSpeakTool::execute_with_decide(&work_args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink.recorded().len(), 1);

        let sink2 = RecordingSink::new(false);
        let subagent_args = McpSpeakArguments {
            priority: SpeechPriority::Subagent,
            ..McpSpeakArguments::new("사실".to_string(), "M1".to_string(), 1.0, 0.8)
        };
        McpSpeakTool::execute_with_decide(&subagent_args, &sink2, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink2.recorded().len(), 1);

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn emotion_auto_is_resolved_by_decide_choice() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.9), choice: Some("warm".to_string()) };
        let args = McpSpeakArguments {
            emotion_auto: true,
            ..McpSpeakArguments::new("고맙습니다".to_string(), "F1".to_string(), 1.0, 1.0)
        };
        McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink.recorded()[0].emotion, SpeechEmotion::Warm);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn emotion_auto_falls_back_to_neutral_when_decide_unavailable() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.9), choice: None };
        let args = McpSpeakArguments {
            emotion_auto: true,
            ..McpSpeakArguments::new("고맙습니다".to_string(), "F1".to_string(), 1.0, 1.0)
        };
        McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink.recorded()[0].emotion, SpeechEmotion::Neutral);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn subagent_priority_is_promoted_to_main_when_decide_says_important() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.9), choice: Some("promote_main".to_string()) };
        let args = McpSpeakArguments {
            priority: SpeechPriority::Subagent,
            ..McpSpeakArguments::new("중대한 발견".to_string(), "M1".to_string(), 1.0, 0.8)
        };
        McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink.recorded()[0].priority, SpeechPriority::Main);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn subagent_priority_stays_subagent_when_decide_unavailable() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let decide = StubDecide { noul: Some(0.9), choice: None };
        let args = McpSpeakArguments {
            priority: SpeechPriority::Subagent,
            ..McpSpeakArguments::new("사소한 사실".to_string(), "M1".to_string(), 1.0, 0.8)
        };
        McpSpeakTool::execute_with_decide(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None, &decide);
        assert_eq!(sink.recorded()[0].priority, SpeechPriority::Subagent);
        fs::remove_dir_all(&home).ok();
    }
}
