// 발화 요청 수신→큐→합성→재생을 묶는 상주 데몬 루프
use crate::audio_player::AudioPlaying;
use crate::configuration::DebriefConfiguration;
use crate::mode_policy::ModePolicy;
use crate::speech_queue::{QueueDecision, SpeechQueue};
use crate::speech_request::SpeechRequest;
use crate::tts_backend::TtsBackend;
use crate::unix_socket::{is_recoverable_accept_error, UnixSocketError};
use std::sync::{Arc, Mutex};

#[derive(Debug, PartialEq, Eq)]
pub enum DebriefDaemonError {
    MissingRequestSource,
    Accept(UnixSocketError),
}

pub trait SpeechRequestSource: Send + Sync {
    fn accept(&self) -> Result<SpeechRequest, UnixSocketError>;
    fn close(&self);
}

/// `(component, code, message)` — 메뉴 진단을 위한 유계 에러 기록.
pub type ErrorRecorder = dyn Fn(&str, &str, &str) + Send + Sync;

struct DaemonState {
    active: Option<SpeechRequest>,
    discard_active: bool,
    shutting_down: bool,
    worker: Option<std::thread::JoinHandle<()>>,
}

pub struct DebriefDaemon<B: TtsBackend, A: AudioPlaying> {
    source: Option<Box<dyn SpeechRequestSource>>,
    queue: Arc<SpeechQueue>,
    backend: Arc<B>,
    audio: Arc<A>,
    configuration: Arc<dyn Fn() -> DebriefConfiguration + Send + Sync>,
    record_error: Option<Arc<ErrorRecorder>>,
    state: Arc<Mutex<DaemonState>>,
}

impl<B: TtsBackend + 'static, A: AudioPlaying + 'static> DebriefDaemon<B, A> {
    pub fn new(
        source: Option<Box<dyn SpeechRequestSource>>,
        queue: SpeechQueue,
        backend: B,
        audio: A,
        configuration: impl Fn() -> DebriefConfiguration + Send + Sync + 'static,
        record_error: Option<Arc<ErrorRecorder>>,
    ) -> Self {
        DebriefDaemon {
            source,
            queue: Arc::new(queue),
            backend: Arc::new(backend),
            audio: Arc::new(audio),
            configuration: Arc::new(configuration),
            record_error,
            state: Arc::new(Mutex::new(DaemonState { active: None, discard_active: false, shutting_down: false, worker: None })),
        }
    }

    /// 현재 합성/재생 중인 요청의 보이스 id (예: `F1`, `M3`).
    pub fn active_voice(&self) -> Option<String> {
        self.state.lock().unwrap().active.as_ref().map(|r| r.envelope.voice.clone())
    }

    pub fn run(&self) -> Result<(), DebriefDaemonError> {
        let Some(source) = &self.source else { return Err(DebriefDaemonError::MissingRequestSource) };
        loop {
            if self.state.lock().unwrap().shutting_down {
                break;
            }
            match source.accept() {
                Ok(request) => {
                    self.submit(request);
                }
                Err(error) => {
                    if self.state.lock().unwrap().shutting_down {
                        break;
                    }
                    // 깨지거나 일부만 온 클라이언트 프레임이 상주 accept 루프를 무너뜨리면 안 된다.
                    if is_recoverable_accept_error(&error) {
                        continue;
                    }
                    return Err(DebriefDaemonError::Accept(error));
                }
            }
        }
        if !self.state.lock().unwrap().shutting_down {
            self.shutdown();
        }
        Ok(())
    }

    pub fn submit(&self, request: SpeechRequest) -> Option<QueueDecision> {
        {
            let state = self.state.lock().unwrap();
            if state.shutting_down {
                return None;
            }
        }
        let configuration = (self.configuration)();
        ModePolicy::admit(request.priority, request.lane, request.envelope.volume, &configuration)?;

        {
            let mut state = self.state.lock().unwrap();
            if let Some(active) = &state.active {
                if SpeechQueue::should_interrupt_active(active, &request) {
                    state.discard_active = true;
                    self.audio.stop();
                }
            }
        }

        let decision = self.queue.enqueue(request);
        let mut state = self.state.lock().unwrap();
        if decision == QueueDecision::Accepted && state.worker.is_none() {
            let queue = self.queue.clone();
            let backend = self.backend.clone();
            let audio = self.audio.clone();
            let configuration = self.configuration.clone();
            let record_error = self.record_error.clone();
            let shared_state = self.state.clone();
            state.worker = Some(std::thread::spawn(move || {
                Self::consume(queue, backend, audio, configuration, record_error, shared_state);
            }));
        } else if decision == QueueDecision::RejectedCapacity {
            if let Some(record_error) = &self.record_error {
                record_error("queue", "capacity", "발화 대기열이 가득 차 요청을 건너뛰었습니다");
            }
        } else if decision == QueueDecision::RejectedDuplicate {
            if let Some(record_error) = &self.record_error {
                record_error("queue", "duplicate", "동일 발화가 짧은 시간 안에 중복되어 건너뛰었습니다");
            }
        }
        Some(decision)
    }

    pub fn shutdown(&self) {
        let mut state = self.state.lock().unwrap();
        if state.shutting_down {
            return;
        }
        state.shutting_down = true;
        if let Some(source) = &self.source {
            source.close();
        }
        state.discard_active = true;
        self.audio.stop();
        state.active = None;
        // Swift 원본처럼 워커를 detach한다: `queue.next()`에서 블로킹 중이던 소비 스레드가
        // 다음 enqueue 전까지 끝나지 않을 수 있으므로 완료를 기다리지 않는다(fire-and-forget).
        state.worker = None;
    }

    fn consume(
        queue: Arc<SpeechQueue>,
        backend: Arc<B>,
        audio: Arc<A>,
        configuration: Arc<dyn Fn() -> DebriefConfiguration + Send + Sync>,
        record_error: Option<Arc<ErrorRecorder>>,
        state: Arc<Mutex<DaemonState>>,
    ) {
        loop {
            if state.lock().unwrap().shutting_down {
                break;
            }
            let request = queue.next();
            if state.lock().unwrap().shutting_down {
                break;
            }
            {
                let mut guard = state.lock().unwrap();
                guard.active = Some(request.clone());
                guard.discard_active = false;
            }

            match backend.synthesize(&request.envelope.text, &request.envelope.voice, request.envelope.speed) {
                Ok(buffer) => {
                    let discard = state.lock().unwrap().discard_active;
                    if !discard {
                        if let Some(gain) =
                            ModePolicy::admit(request.priority, request.lane, request.envelope.volume, &configuration())
                        {
                            let _ = audio.play(&buffer, gain);
                        }
                    }
                }
                Err(error) => {
                    // 실패한 항목은 버리고 계속한다; 메뉴 진단을 위해 표면화한다.
                    if let Some(record_error) = &record_error {
                        let detail: String = format!("{error:?}").chars().take(80).collect();
                        record_error("tts", "synthesis_or_playback", &format!("합성 또는 재생에 실패했습니다: {detail}"));
                    }
                }
            }
            let mut guard = state.lock().unwrap();
            guard.active = None;
            guard.discard_active = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::configuration::DebriefMode;
    use crate::speech_emotion::SpeechEmotion;
    use crate::speech_envelope::SpeechEnvelope;
    use crate::speech_lane::SpeechLane;
    use crate::speech_request::SpeechPriority;
    use std::collections::HashMap;
    use std::sync::Condvar;
    use std::time::Duration;

    struct RecordingBackend {
        failing_text: Option<String>,
        texts: Mutex<Vec<String>>,
    }
    impl RecordingBackend {
        fn new(failing_text: Option<&str>) -> Self {
            RecordingBackend { failing_text: failing_text.map(|s| s.to_string()), texts: Mutex::new(Vec::new()) }
        }
        fn texts(&self) -> Vec<String> {
            self.texts.lock().unwrap().clone()
        }
        fn wait_until_count(&self, count: usize) {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while self.texts.lock().unwrap().len() < count && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
    impl TtsBackend for RecordingBackend {
        fn synthesize(&self, text: &str, _voice: &str, _speed: f64) -> Result<crate::tts_backend::PcmBuffer, crate::tts_backend::TtsBackendError> {
            self.texts.lock().unwrap().push(text.to_string());
            if self.failing_text.as_deref() == Some(text) {
                return Err(crate::tts_backend::TtsBackendError::SynthesisFailed);
            }
            Ok(crate::tts_backend::PcmBuffer { sample_rate: 44_100.0, channels: 1, samples: vec![text.len() as f32] })
        }
    }

    struct RecordingAudio {
        blocking_marker: Option<i64>,
        markers: Mutex<Vec<i64>>,
        gains: Mutex<Vec<f64>>,
        stop_count: Mutex<usize>,
        blocked: Mutex<Option<i64>>,
        condvar: Condvar,
    }
    impl RecordingAudio {
        fn new(blocking_marker: Option<i64>) -> Self {
            RecordingAudio {
                blocking_marker,
                markers: Mutex::new(Vec::new()),
                gains: Mutex::new(Vec::new()),
                stop_count: Mutex::new(0),
                blocked: Mutex::new(None),
                condvar: Condvar::new(),
            }
        }
        fn markers(&self) -> Vec<i64> {
            self.markers.lock().unwrap().clone()
        }
        fn gains(&self) -> Vec<f64> {
            self.gains.lock().unwrap().clone()
        }
        fn stop_count(&self) -> usize {
            *self.stop_count.lock().unwrap()
        }
        fn wait_until_started(&self, marker: i64) {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while !self.markers.lock().unwrap().contains(&marker) && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        fn wait_until_count(&self, count: usize) {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while self.markers.lock().unwrap().len() < count && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
    impl AudioPlaying for RecordingAudio {
        fn play(&self, buffer: &crate::tts_backend::PcmBuffer, gain: f64) -> Result<(), crate::audio_player::AudioPlayerError> {
            let marker = buffer.samples.first().map(|s| *s as i64).unwrap_or(0);
            self.markers.lock().unwrap().push(marker);
            self.gains.lock().unwrap().push(gain);
            if Some(marker) == self.blocking_marker {
                let mut blocked = self.blocked.lock().unwrap();
                *blocked = Some(marker);
                while blocked.is_some() {
                    blocked = self.condvar.wait(blocked).unwrap();
                }
            }
            Ok(())
        }
        fn stop(&self) {
            *self.stop_count.lock().unwrap() += 1;
            let mut blocked = self.blocked.lock().unwrap();
            *blocked = None;
            self.condvar.notify_all();
        }
    }

    fn request(priority: SpeechPriority, text: &str, volume: f64) -> SpeechRequest {
        SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: text.to_string(), voice: "F1".to_string(), speed: 0.93, volume },
            priority,
            lane: SpeechLane::Companion,
            emotion: SpeechEmotion::Neutral,
            agent_type: if matches!(priority, SpeechPriority::Subagent) { Some("explore".to_string()) } else { None },
        }
    }

    #[test]
    fn preserves_order_clamps_gain_and_continues_after_synthesis_failure() {
        let backend = RecordingBackend::new(Some("bad"));
        let audio = RecordingAudio::new(None);
        let mut ceilings = HashMap::new();
        ceilings.insert("normal".to_string(), 0.4);
        let configuration =
            DebriefConfiguration { mode: DebriefMode::Normal, muted: false, volume_ceilings: ceilings, ..Default::default() };
        let entries: Arc<Mutex<Vec<(String, String, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let entries_clone = entries.clone();
        let record_error: Arc<ErrorRecorder> =
            Arc::new(move |component, code, message| entries_clone.lock().unwrap().push((component.to_string(), code.to_string(), message.to_string())));
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), backend, audio, move || configuration.clone(), Some(record_error));

        daemon.submit(request(SpeechPriority::Main, "one", 0.9));
        daemon.submit(request(SpeechPriority::Main, "bad", 0.8));
        daemon.submit(request(SpeechPriority::Main, "three", 0.7));
        daemon.backend.wait_until_count(3);
        daemon.audio.wait_until_count(2);

        assert_eq!(daemon.backend.texts(), vec!["one".to_string(), "bad".to_string(), "three".to_string()]);
        assert_eq!(daemon.audio.markers(), vec![3, 5]);
        assert_eq!(daemon.audio.gains(), vec![0.4, 0.4]);
        assert!(entries.lock().unwrap().iter().any(|(c, code, _)| c == "tts" && code == "synthesis_or_playback"));
        daemon.shutdown();
    }

    #[test]
    fn focus_mode_rejects_subagent_priority() {
        let backend = RecordingBackend::new(None);
        let audio = RecordingAudio::new(None);
        let config = DebriefConfiguration { mode: DebriefMode::Focus, muted: false, ..Default::default() };
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), backend, audio, move || config.clone(), None);

        let decision = daemon.submit(request(SpeechPriority::Subagent, "skip-me", 0.5));
        assert_eq!(decision, None);
        daemon.submit(request(SpeechPriority::Main, "keep", 0.5));
        daemon.backend.wait_until_count(1);
        assert_eq!(daemon.backend.texts(), vec!["keep".to_string()]);
        daemon.shutdown();
    }

    #[test]
    fn companion_disabled_rejects_companion_lane() {
        let backend = RecordingBackend::new(None);
        let audio = RecordingAudio::new(None);
        let config = DebriefConfiguration { mode: DebriefMode::Normal, muted: false, companion_enabled: false, ..Default::default() };
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), backend, audio, move || config.clone(), None);

        let companion = SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: "hi".to_string(), voice: "F1".to_string(), speed: 1.0, volume: 0.5 },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Companion,
            emotion: SpeechEmotion::Warm,
            agent_type: None,
        };
        let work = SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: "work".to_string(), voice: "M1".to_string(), speed: 1.0, volume: 0.5 },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Work,
            emotion: SpeechEmotion::Neutral,
            agent_type: None,
        };
        assert_eq!(daemon.submit(companion), None);
        daemon.submit(work);
        daemon.backend.wait_until_count(1);
        assert_eq!(daemon.backend.texts(), vec!["work".to_string()]);
        daemon.shutdown();
    }

    #[test]
    fn main_interrupts_active_subagent_and_drops_queued_subagents() {
        let backend = RecordingBackend::new(None);
        let audio = RecordingAudio::new(Some(10));
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), backend, audio, DebriefConfiguration::default, None);

        daemon.submit(request(SpeechPriority::Subagent, "sub-active", 0.5));
        daemon.audio.wait_until_started(10);
        daemon.submit(request(SpeechPriority::Subagent, "sub-queued", 0.5));
        daemon.submit(request(SpeechPriority::Main, "main", 0.8));
        daemon.backend.wait_until_count(2);
        daemon.audio.wait_until_count(2);

        assert_eq!(daemon.audio.stop_count(), 1);
        assert_eq!(daemon.backend.texts(), vec!["sub-active".to_string(), "main".to_string()]);
        assert_eq!(daemon.audio.markers(), vec![10, 4]);
        daemon.shutdown();
    }

    struct WaitingSource {
        accepting: Mutex<bool>,
        condvar: Condvar,
        close_count: Mutex<usize>,
        unblock: Mutex<bool>,
    }
    impl WaitingSource {
        fn new() -> Self {
            WaitingSource { accepting: Mutex::new(false), condvar: Condvar::new(), close_count: Mutex::new(0), unblock: Mutex::new(false) }
        }
        fn wait_until_accepting(&self) {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while !*self.accepting.lock().unwrap() && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
    impl SpeechRequestSource for WaitingSource {
        fn accept(&self) -> Result<SpeechRequest, UnixSocketError> {
            *self.accepting.lock().unwrap() = true;
            let mut unblock = self.unblock.lock().unwrap();
            while !*unblock {
                unblock = self.condvar.wait(unblock).unwrap();
            }
            Err(UnixSocketError::Disconnected)
        }
        fn close(&self) {
            *self.close_count.lock().unwrap() += 1;
            *self.unblock.lock().unwrap() = true;
            self.condvar.notify_all();
        }
    }

    #[test]
    fn shutdown_stops_audio_and_terminates_run_loop() {
        let source = Arc::new(WaitingSource::new());
        struct SourceAdapter(Arc<WaitingSource>);
        impl SpeechRequestSource for SourceAdapter {
            fn accept(&self) -> Result<SpeechRequest, UnixSocketError> {
                self.0.accept()
            }
            fn close(&self) {
                self.0.close()
            }
        }
        let audio = Arc::new(RecordingAudio::new(None));
        struct AudioAdapter(Arc<RecordingAudio>);
        impl AudioPlaying for AudioAdapter {
            fn play(&self, buffer: &crate::tts_backend::PcmBuffer, gain: f64) -> Result<(), crate::audio_player::AudioPlayerError> {
                self.0.play(buffer, gain)
            }
            fn stop(&self) {
                self.0.stop()
            }
        }

        let daemon = Arc::new(DebriefDaemon::new(
            Some(Box::new(SourceAdapter(source.clone()))),
            SpeechQueue::new(8, Duration::ZERO),
            RecordingBackend::new(None),
            AudioAdapter(audio.clone()),
            DebriefConfiguration::default,
            None,
        ));
        let run_daemon = daemon.clone();
        let run = std::thread::spawn(move || run_daemon.run());
        source.wait_until_accepting();

        daemon.shutdown();
        run.join().unwrap().unwrap();

        assert_eq!(audio.stop_count(), 1);
        assert_eq!(*source.close_count.lock().unwrap(), 1);
    }

    struct SequenceSource {
        results: Mutex<Vec<Result<SpeechRequest, UnixSocketError>>>,
    }
    impl SpeechRequestSource for SequenceSource {
        fn accept(&self) -> Result<SpeechRequest, UnixSocketError> {
            let mut results = self.results.lock().unwrap();
            if results.is_empty() {
                return Err(UnixSocketError::Disconnected);
            }
            results.remove(0)
        }
        fn close(&self) {}
    }

    #[test]
    fn recoverable_accept_errors_do_not_terminate_run_loop() {
        let good = request(SpeechPriority::Main, "after-bad", 0.8);
        let source = SequenceSource {
            results: Mutex::new(vec![
                Err(UnixSocketError::InvalidFrame),
                Err(UnixSocketError::PayloadTooLarge),
                Ok(good),
                Err(UnixSocketError::Disconnected),
            ]),
        };
        let backend = Arc::new(RecordingBackend::new(None));
        struct BackendAdapter(Arc<RecordingBackend>);
        impl TtsBackend for BackendAdapter {
            fn synthesize(&self, text: &str, voice: &str, speed: f64) -> Result<crate::tts_backend::PcmBuffer, crate::tts_backend::TtsBackendError> {
                self.0.synthesize(text, voice, speed)
            }
        }
        let daemon = DebriefDaemon::new(
            Some(Box::new(source)),
            SpeechQueue::new(8, Duration::ZERO),
            BackendAdapter(backend.clone()),
            RecordingAudio::new(None),
            DebriefConfiguration::default,
            None,
        );
        let result = daemon.run();
        backend.wait_until_count(1);
        assert_eq!(result, Err(DebriefDaemonError::Accept(UnixSocketError::Disconnected)));
        assert_eq!(backend.texts(), vec!["after-bad".to_string()]);
        assert!(is_recoverable_accept_error(&UnixSocketError::InvalidFrame));
        assert!(is_recoverable_accept_error(&UnixSocketError::PayloadTooLarge));
        assert!(!is_recoverable_accept_error(&UnixSocketError::Disconnected));
    }
}
