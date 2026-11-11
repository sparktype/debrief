// cpal 기반 오디오 재생 — debrief-core의 AudioPlaying 트레이트 구현
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use debrief_core::{AudioPlayerError, AudioPlaying, PcmBuffer};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};

pub(crate) trait AudioEngineDriving: Send + Sync {
    fn play(&self, samples: &[f32], sample_rate: f64) -> Result<(), AudioPlayerError>;
    fn stop(&self);
    fn rebuild(&self) -> Result<(), AudioPlayerError>;
}

pub struct AudioPlayer {
    driver: Box<dyn AudioEngineDriving>,
}

impl AudioPlayer {
    pub fn new() -> Self {
        AudioPlayer { driver: Box::new(CpalAudioDriver::new()) }
    }

    #[cfg(test)]
    pub(crate) fn with_driver(driver: Box<dyn AudioEngineDriving>) -> Self {
        AudioPlayer { driver }
    }
}

impl Default for AudioPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioPlaying for AudioPlayer {
    fn play(&self, buffer: &PcmBuffer, gain: f64) -> Result<(), AudioPlayerError> {
        if buffer.channels != 1
            || buffer.sample_rate != 44_100.0
            || buffer.samples.is_empty()
            || !buffer.samples.iter().all(|s| s.is_finite())
            || !gain.is_finite()
        {
            return Err(AudioPlayerError::InvalidBuffer);
        }
        let admitted_gain = gain.clamp(0.0, 1.0) as f32;
        let samples: Vec<f32> = buffer.samples.iter().map(|s| s * admitted_gain).collect();
        if self.driver.play(&samples, buffer.sample_rate).is_err() {
            self.driver.rebuild()?;
            self.driver.play(&samples, buffer.sample_rate)?;
        }
        Ok(())
    }

    fn stop(&self) {
        self.driver.stop();
    }
}

struct PlaybackState {
    samples: Vec<f32>,
    position: AtomicUsize,
    stopped: AtomicBool,
    /// `stopped` 이후 페이드아웃에 이미 내보낸 샘플 수.
    fade_pos: AtomicUsize,
    /// 장치가 사라지는 등 스트림이 죽어 끝난 경우. 정상 종료·`stop`과 구분한다.
    failed: AtomicBool,
    finished: Mutex<bool>,
    finished_signal: Condvar,
}

impl PlaybackState {
    /// 클립 길이에 더하는 여유. 장치가 오류도 없이 콜백을 멈춘 경우에도 재생 스레드가 영원히 묶이지 않게 한다.
    const STALL_MARGIN: std::time::Duration = std::time::Duration::from_secs(3);

    fn new(samples: Vec<f32>) -> Self {
        PlaybackState {
            samples,
            position: AtomicUsize::new(0),
            stopped: AtomicBool::new(false),
            fade_pos: AtomicUsize::new(0),
            failed: AtomicBool::new(false),
            finished: Mutex::new(false),
            finished_signal: Condvar::new(),
        }
    }

    /// 중단 시 페이드아웃 길이(44.1kHz 기준 60ms). 뚝 끊기는 클릭을 없앤다.
    const FADE_SAMPLES: usize = 2_646;
    /// 페이드가 끝나길 기다리는 상한. 콜백이 안 돌아도 `stop`이 묶이지 않게 한다.
    const FADE_WAIT: std::time::Duration = std::time::Duration::from_millis(200);

    /// 출력 버퍼를 채운다. 중단 요청이 있으면 남은 소리를 선형으로 줄여 0으로 만든다.
    fn fill(&self, data: &mut [f32]) {
        let start = self.position.load(Ordering::SeqCst);
        let remaining = self.samples.len().saturating_sub(start);
        let to_copy = remaining.min(data.len());
        data[..to_copy].copy_from_slice(&self.samples[start..start + to_copy]);
        data[to_copy..].fill(0.0);
        self.position.store(start + to_copy, Ordering::SeqCst);

        if self.stopped.load(Ordering::SeqCst) {
            let faded = self.fade_pos.load(Ordering::SeqCst);
            for (i, sample) in data.iter_mut().enumerate() {
                let n = faded + i;
                *sample *= if n >= Self::FADE_SAMPLES { 0.0 } else { 1.0 - n as f32 / Self::FADE_SAMPLES as f32 };
            }
            self.fade_pos.store(faded + data.len(), Ordering::SeqCst);
            if faded + data.len() >= Self::FADE_SAMPLES {
                self.signal_finished();
                return;
            }
        }
        if start + to_copy >= self.samples.len() {
            self.signal_finished();
        }
    }

    fn wait_limit(sample_count: usize, sample_rate: f64) -> std::time::Duration {
        std::time::Duration::from_secs_f64(sample_count as f64 / sample_rate) + Self::STALL_MARGIN
    }

    fn signal_finished(&self) {
        let mut finished = self.finished.lock().unwrap();
        *finished = true;
        self.finished_signal.notify_all();
    }

    fn signal_failed(&self) {
        self.failed.store(true, Ordering::SeqCst);
        self.signal_finished();
    }

    /// 재생이 끝날 때까지 기다린다. 스트림 오류나 `limit` 초과는 `PlaybackFailed`다.
    fn wait(&self, limit: std::time::Duration) -> Result<(), AudioPlayerError> {
        let finished = self.finished.lock().unwrap();
        let (finished, _) = self.finished_signal.wait_timeout_while(finished, limit, |done| !*done).unwrap();
        if !*finished || self.failed.load(Ordering::SeqCst) {
            return Err(AudioPlayerError::PlaybackFailed);
        }
        Ok(())
    }
}

struct CpalAudioDriver {
    state: Mutex<Option<(Arc<PlaybackState>, cpal::Stream)>>,
}

impl CpalAudioDriver {
    fn new() -> Self {
        CpalAudioDriver { state: Mutex::new(None) }
    }
}

impl AudioEngineDriving for CpalAudioDriver {
    fn play(&self, samples: &[f32], sample_rate: f64) -> Result<(), AudioPlayerError> {
        // 이전 재생이 남아있으면 멈춘다 — Swift의 player.stop()+scheduleBuffer 교체와 동일.
        self.stop();

        let host = cpal::default_host();
        let device = host.default_output_device().ok_or(AudioPlayerError::PlaybackFailed)?;
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: sample_rate as cpal::SampleRate,
            buffer_size: cpal::BufferSize::Default,
        };

        let state = Arc::new(PlaybackState::new(samples.to_vec()));
        let callback_state = state.clone();
        let error_state = state.clone();

        let stream = device
            .build_output_stream(
                config,
                move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                    callback_state.fill(data);
                },
                move |error: cpal::Error| {
                    // DeviceChanged는 cpal이 스트림을 새 기본 장치로 옮기므로 계속 재생한다.
                    if matches!(
                        error.kind(),
                        cpal::ErrorKind::DeviceNotAvailable | cpal::ErrorKind::StreamInvalidated | cpal::ErrorKind::HostUnavailable
                    ) {
                        error_state.signal_failed();
                    }
                },
                None,
            )
            .map_err(|_| AudioPlayerError::InvalidBuffer)?;

        stream.play().map_err(|_| AudioPlayerError::PlaybackFailed)?;

        {
            let mut held = self.state.lock().unwrap();
            *held = Some((state.clone(), stream));
        }

        // 실패하면 AudioPlayer가 rebuild 뒤 한 번 더 시도한다. 끊긴 스트림은 여기서 놓아 준다.
        let outcome = state.wait(PlaybackState::wait_limit(samples.len(), sample_rate));
        if outcome.is_err() {
            self.stop();
        }
        outcome
    }

    fn stop(&self) {
        if let Some((state, _stream)) = self.state.lock().unwrap().take() {
            state.stopped.store(true, Ordering::SeqCst);
            // 스트림을 놓기 전에 페이드아웃이 끝나길 기다린다. 콜백이 완료를 알리면 재생 스레드도 함께 깬다.
            let _ = state.wait(PlaybackState::FADE_WAIT);
            state.signal_finished();
        }
    }

    fn rebuild(&self) -> Result<(), AudioPlayerError> {
        self.stop();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    struct FakeAudioDriver {
        fail_first_play: bool,
        play_attempts: StdMutex<usize>,
        rebuild_count: StdMutex<usize>,
        last_samples: StdMutex<Vec<f32>>,
    }
    impl FakeAudioDriver {
        fn new(fail_first_play: bool) -> Self {
            FakeAudioDriver {
                fail_first_play,
                play_attempts: StdMutex::new(0),
                rebuild_count: StdMutex::new(0),
                last_samples: StdMutex::new(Vec::new()),
            }
        }
    }
    impl AudioEngineDriving for FakeAudioDriver {
        fn play(&self, samples: &[f32], _sample_rate: f64) -> Result<(), AudioPlayerError> {
            let mut attempts = self.play_attempts.lock().unwrap();
            *attempts += 1;
            if self.fail_first_play && *attempts == 1 {
                return Err(AudioPlayerError::PlaybackFailed);
            }
            *self.last_samples.lock().unwrap() = samples.to_vec();
            Ok(())
        }
        fn stop(&self) {}
        fn rebuild(&self) -> Result<(), AudioPlayerError> {
            *self.rebuild_count.lock().unwrap() += 1;
            Ok(())
        }
    }

    #[test]
    fn scales_gain_and_rebuilds_exactly_once_after_driver_failure() {
        let driver = Arc::new(FakeAudioDriver::new(true));
        struct DriverRef(Arc<FakeAudioDriver>);
        impl AudioEngineDriving for DriverRef {
            fn play(&self, samples: &[f32], sample_rate: f64) -> Result<(), AudioPlayerError> {
                self.0.play(samples, sample_rate)
            }
            fn stop(&self) {
                self.0.stop()
            }
            fn rebuild(&self) -> Result<(), AudioPlayerError> {
                self.0.rebuild()
            }
        }
        let player = AudioPlayer::with_driver(Box::new(DriverRef(driver.clone())));
        let buffer = PcmBuffer { sample_rate: 44_100.0, channels: 1, samples: vec![1.0, -0.5, 2.0] };

        player.play(&buffer, 0.4).unwrap();

        assert_eq!(*driver.rebuild_count.lock().unwrap(), 1);
        assert_eq!(*driver.play_attempts.lock().unwrap(), 2);
        assert_eq!(*driver.last_samples.lock().unwrap(), vec![0.4, -0.2, 0.8]);
    }

    #[test]
    fn wait_returns_ok_once_playback_signals_finished() {
        let state = Arc::new(PlaybackState::new(vec![0.0; 4]));
        let signaller = state.clone();
        let thread = std::thread::spawn(move || signaller.signal_finished());

        assert_eq!(state.wait(std::time::Duration::from_secs(5)), Ok(()));
        thread.join().unwrap();
    }

    #[test]
    fn wait_fails_fast_when_the_stream_reports_a_dead_device() {
        let state = Arc::new(PlaybackState::new(vec![0.0; 4]));
        let signaller = state.clone();
        let thread = std::thread::spawn(move || signaller.signal_failed());

        assert_eq!(state.wait(std::time::Duration::from_secs(5)), Err(AudioPlayerError::PlaybackFailed));
        thread.join().unwrap();
    }

    #[test]
    fn wait_gives_up_when_the_device_goes_silent_without_an_error() {
        let state = PlaybackState::new(vec![0.0; 4]);

        assert_eq!(state.wait(std::time::Duration::from_millis(30)), Err(AudioPlayerError::PlaybackFailed));
    }

    #[test]
    fn stop_fades_out_to_silence_then_signals_finished() {
        let state = PlaybackState::new(vec![1.0; PlaybackState::FADE_SAMPLES * 2]);
        state.stopped.store(true, Ordering::SeqCst);
        let mut first = vec![0.0; 1000];
        state.fill(&mut first);
        assert!(first[0] > 0.99 && first.windows(2).all(|w| w[1] < w[0]), "점점 줄어든다");
        assert!(!*state.finished.lock().unwrap());

        let mut rest = vec![0.0; PlaybackState::FADE_SAMPLES];
        state.fill(&mut rest);
        assert!(rest[rest.len() - 1000..].iter().all(|s| *s == 0.0), "끝은 무음");
        assert!(*state.finished.lock().unwrap());
    }

    #[test]
    fn wait_limit_is_clip_duration_plus_margin() {
        assert_eq!(PlaybackState::wait_limit(44_100, 44_100.0), std::time::Duration::from_secs(1) + PlaybackState::STALL_MARGIN);
    }

    #[test]
    fn rejects_invalid_pcm_without_calling_driver() {
        let driver = Arc::new(FakeAudioDriver::new(false));
        struct DriverRef(Arc<FakeAudioDriver>);
        impl AudioEngineDriving for DriverRef {
            fn play(&self, samples: &[f32], sample_rate: f64) -> Result<(), AudioPlayerError> {
                self.0.play(samples, sample_rate)
            }
            fn stop(&self) {
                self.0.stop()
            }
            fn rebuild(&self) -> Result<(), AudioPlayerError> {
                self.0.rebuild()
            }
        }
        let player = AudioPlayer::with_driver(Box::new(DriverRef(driver.clone())));

        let result = player.play(&PcmBuffer { sample_rate: 44_100.0, channels: 2, samples: vec![0.0, 0.0] }, 1.0);
        assert_eq!(result, Err(AudioPlayerError::InvalidBuffer));
        assert_eq!(*driver.play_attempts.lock().unwrap(), 0);
    }
}
