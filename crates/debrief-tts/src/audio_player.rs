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
    finished: Mutex<bool>,
    finished_signal: Condvar,
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

        let state = Arc::new(PlaybackState {
            samples: samples.to_vec(),
            position: AtomicUsize::new(0),
            stopped: AtomicBool::new(false),
            finished: Mutex::new(false),
            finished_signal: Condvar::new(),
        });
        let callback_state = state.clone();

        let stream = device
            .build_output_stream(
                config,
                move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                    if callback_state.stopped.load(Ordering::SeqCst) {
                        data.fill(0.0);
                        Self::signal_finished(&callback_state);
                        return;
                    }
                    let start = callback_state.position.load(Ordering::SeqCst);
                    let remaining = callback_state.samples.len().saturating_sub(start);
                    let to_copy = remaining.min(data.len());
                    data[..to_copy].copy_from_slice(&callback_state.samples[start..start + to_copy]);
                    for sample in &mut data[to_copy..] {
                        *sample = 0.0;
                    }
                    callback_state.position.store(start + to_copy, Ordering::SeqCst);
                    if start + to_copy >= callback_state.samples.len() {
                        Self::signal_finished(&callback_state);
                    }
                },
                move |_error| {},
                None,
            )
            .map_err(|_| AudioPlayerError::InvalidBuffer)?;

        stream.play().map_err(|_| AudioPlayerError::PlaybackFailed)?;

        {
            let mut held = self.state.lock().unwrap();
            *held = Some((state.clone(), stream));
        }

        let mut finished = state.finished.lock().unwrap();
        while !*finished {
            finished = state.finished_signal.wait(finished).unwrap();
        }
        Ok(())
    }

    fn stop(&self) {
        if let Some((state, _stream)) = self.state.lock().unwrap().take() {
            state.stopped.store(true, Ordering::SeqCst);
            Self::signal_finished(&state);
        }
    }

    fn rebuild(&self) -> Result<(), AudioPlayerError> {
        self.stop();
        Ok(())
    }
}

impl CpalAudioDriver {
    fn signal_finished(state: &PlaybackState) {
        let mut finished = state.finished.lock().unwrap();
        *finished = true;
        state.finished_signal.notify_all();
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
