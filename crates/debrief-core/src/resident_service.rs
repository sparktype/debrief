// TTS 상주 프로세스 시작/중지 라이프사이클 (pid·소켓·데몬)
use crate::audio_player::AudioPlaying;
use crate::configuration::DebriefConfiguration;
use crate::debrief_daemon::{DebriefDaemon, DebriefDaemonError, SpeechRequestSource};
use crate::diagnostics::Diagnostics;
use crate::model_installer::InstalledModel;
use crate::paths::DebriefPaths;
use crate::speech_queue::SpeechQueue;
use crate::tts_backend::TtsBackend;
use crate::unix_socket::{UnixSocketError, UnixSocketServer};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Debug, PartialEq, Eq)]
pub enum ResidentServiceError {
    AlreadyRunning,
    ModelUnavailable,
    NotRunning,
}

/// 다른 살아있는 프로세스가 이미 상주 pid 파일을 소유하고 있으면 true.
pub fn is_foreign_host_running(home: &Path, process_exists: &dyn Fn(i32) -> bool) -> bool {
    let paths = DebriefPaths::for_home(home);
    let Ok(existing) = std::fs::read_to_string(&paths.pid_url) else { return false };
    let Ok(pid) = existing.trim().parse::<i32>() else { return false };
    if pid <= 0 || pid == std::process::id() as i32 {
        return false;
    }
    process_exists(pid)
}

impl SpeechRequestSource for UnixSocketServer {
    fn accept(&self) -> Result<crate::speech_request::SpeechRequest, UnixSocketError> {
        UnixSocketServer::accept(self)
    }
    fn close(&self) {
        self.request_close();
    }
}

struct ResidentState<B: TtsBackend, A: AudioPlaying> {
    server: Option<Arc<UnixSocketServer>>,
    daemon: Option<Arc<DebriefDaemon<B, A>>>,
    run_thread: Option<std::thread::JoinHandle<()>>,
    owned_pid: Option<String>,
    running: bool,
    intentional_stop: Arc<std::sync::atomic::AtomicBool>,
    remove_pid_on_clear: bool,
    run_failure: Option<DebriefDaemonError>,
}

/// 모델/백엔드 팩토리의 실패 표지 — Swift 원본은 임의 에러를 던지지만, 호출부는
/// `ResidentServiceError::ModelUnavailable`로만 번역하므로 세부 원인을 보존할 필요가 없다.
#[derive(Debug)]
pub struct ProvisioningFailed;

pub type ModelDirectoryProvider = Box<dyn Fn(&DebriefPaths) -> Result<PathBuf, ProvisioningFailed> + Send + Sync>;
pub type BackendFactory<B> = Box<dyn Fn(&Path) -> Result<B, ProvisioningFailed> + Send + Sync>;
pub type AudioFactory<A> = Box<dyn Fn() -> A + Send + Sync>;
pub type SocketFactory = Box<dyn Fn(&Path) -> Result<Arc<UnixSocketServer>, UnixSocketError> + Send + Sync>;
pub type ProcessExistsCheck = Box<dyn Fn(i32) -> bool + Send + Sync>;

pub struct ResidentService<B: TtsBackend + 'static, A: AudioPlaying + 'static> {
    home: PathBuf,
    model_directory_provider: ModelDirectoryProvider,
    backend_factory: BackendFactory<B>,
    audio_factory: AudioFactory<A>,
    socket_factory: SocketFactory,
    process_exists: ProcessExistsCheck,
    state: Arc<Mutex<ResidentState<B, A>>>,
}

impl<B: TtsBackend + 'static, A: AudioPlaying + 'static> ResidentService<B, A> {
    pub fn new(
        home: PathBuf,
        model_directory_provider: ModelDirectoryProvider,
        backend_factory: BackendFactory<B>,
        audio_factory: AudioFactory<A>,
        socket_factory: Option<SocketFactory>,
        process_exists: Option<ProcessExistsCheck>,
    ) -> Self {
        ResidentService {
            home,
            model_directory_provider,
            backend_factory,
            audio_factory,
            socket_factory: socket_factory
                .unwrap_or_else(|| Box::new(|url| UnixSocketServer::new(url.to_path_buf()).map(Arc::new))),
            process_exists: process_exists.unwrap_or_else(|| Box::new(Self::live_process_exists)),
            state: Arc::new(Mutex::new(ResidentState {
                server: None,
                daemon: None,
                run_thread: None,
                owned_pid: None,
                running: false,
                intentional_stop: Arc::new(std::sync::atomic::AtomicBool::new(false)),
                remove_pid_on_clear: true,
                run_failure: None,
            })),
        }
    }

    fn live_process_exists(pid: i32) -> bool {
        // SAFETY: kill(pid, 0) sends no signal and only probes liveness/visibility.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    pub fn default_model_directory_provider(paths: &DebriefPaths) -> Result<PathBuf, ProvisioningFailed> {
        InstalledModel::resolve_current(&paths.models_directory, "supertonic-3")
            .map(|m| m.directory)
            .map_err(|_| ProvisioningFailed)
    }

    pub fn is_running(&self) -> bool {
        self.state.lock().unwrap().running
    }

    /// 합성/재생 중인 보이스 id (있다면).
    pub fn active_voice(&self) -> Option<String> {
        self.state.lock().unwrap().daemon.as_ref().and_then(|d| d.active_voice())
    }

    /// 실행 루프를 끝낸 에러를 돌려주고 비운다 (의도된 stop()은 실패를 만들지 않는다).
    pub fn consume_run_failure(&self) -> Option<DebriefDaemonError> {
        self.state.lock().unwrap().run_failure.take()
    }

    pub fn start(&self) -> Result<(), ResidentServiceError> {
        let mut state = self.state.lock().unwrap();
        if state.running {
            return Err(ResidentServiceError::AlreadyRunning);
        }
        let paths = DebriefPaths::for_home(&self.home);

        // 외부 호스트의 살아있는 pid 하나만으로도 alreadyRunning이다(메뉴 Stop 뒤 소켓이 없을 수 있음).
        if let Ok(existing) = std::fs::read_to_string(&paths.pid_url) {
            if let Ok(pid) = existing.trim().parse::<i32>() {
                if pid > 0 && pid != std::process::id() as i32 && (self.process_exists)(pid) {
                    return Err(ResidentServiceError::AlreadyRunning);
                }
            }
        }

        std::fs::create_dir_all(paths.pid_url.parent().unwrap()).map_err(|_| ResidentServiceError::ModelUnavailable)?;

        let model_directory = (self.model_directory_provider)(&paths).map_err(|_| ResidentServiceError::ModelUnavailable)?;
        let backend = (self.backend_factory)(&model_directory).map_err(|_| ResidentServiceError::ModelUnavailable)?;
        let server =
            (self.socket_factory)(&paths.socket_url).map_err(|_| ResidentServiceError::ModelUnavailable)?;

        let home_for_diagnostics = self.home.clone();
        let config_url = paths.config_url.clone();
        let home_for_dnd = self.home.clone();
        let intentional_stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let record_error_intentional = intentional_stop.clone();
        let record_error: Arc<crate::debrief_daemon::ErrorRecorder> = Arc::new(move |component, code, message| {
            let _ = record_error_intentional; // referenced for symmetry with Swift's capture; recordError always runs here
            let _ = Diagnostics::new(&home_for_diagnostics).record_error(component, code, message);
        });

        struct ServerSource(Arc<UnixSocketServer>);
        impl SpeechRequestSource for ServerSource {
            fn accept(&self) -> Result<crate::speech_request::SpeechRequest, UnixSocketError> {
                self.0.accept()
            }
            fn close(&self) {
                self.0.request_close();
            }
        }

        let daemon = Arc::new(DebriefDaemon::new(
            Some(Box::new(ServerSource(server.clone()))),
            SpeechQueue::default(),
            backend,
            (self.audio_factory)(),
            move || DebriefConfiguration::load_effective(&config_url, &home_for_dnd),
            Some(record_error),
        ));

        let pid = std::process::id().to_string();
        std::fs::write(&paths.pid_url, &pid).map_err(|_| ResidentServiceError::ModelUnavailable)?;
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&paths.pid_url, std::fs::Permissions::from_mode(0o600));
        }

        state.server = Some(server);
        state.daemon = Some(daemon.clone());
        state.owned_pid = Some(pid);
        state.running = true;
        intentional_stop.store(false, std::sync::atomic::Ordering::SeqCst);
        state.intentional_stop = intentional_stop.clone();
        state.remove_pid_on_clear = true;
        state.run_failure = None;

        let home_for_thread = self.home.clone();
        let run_intentional = intentional_stop;
        let daemon_for_thread = daemon;
        let state_for_thread = self.state.clone();
        let thread = std::thread::spawn(move || {
            let result = daemon_for_thread.run();
            if let Err(error) = result {
                if !run_intentional.load(std::sync::atomic::Ordering::SeqCst) {
                    let message = Self::describe_run_failure(&error);
                    let _ = Diagnostics::new(&home_for_thread).record_error("daemon", "run_failed", &message);
                    state_for_thread.lock().unwrap().run_failure = Some(error);
                }
            }
            Self::clear_state_if_owned_locked(&state_for_thread, &home_for_thread);
        });
        state.run_thread = Some(thread);

        Ok(())
    }

    fn describe_run_failure(error: &DebriefDaemonError) -> String {
        match error {
            DebriefDaemonError::Accept(UnixSocketError::Disconnected) => "TTS 수신 루프가 종료되었습니다".to_string(),
            DebriefDaemonError::Accept(UnixSocketError::SystemCall(name, code)) => format!("소켓 {name} 오류 ({code})"),
            DebriefDaemonError::Accept(other) => format!("TTS 서비스 오류: {other:?}"),
            DebriefDaemonError::MissingRequestSource => "TTS 서비스 오류: missing request source".to_string(),
        }
    }

    /// 모델이 없거나 유효하지 않다. last-error.json을 기록하고 pid를 쓰되 소켓은 열지 않는다.
    pub fn park_without_socket(&self, message: &str) -> Result<(), ResidentServiceError> {
        let mut state = self.state.lock().unwrap();
        if state.running {
            return Err(ResidentServiceError::AlreadyRunning);
        }
        let paths = DebriefPaths::for_home(&self.home);
        if is_foreign_host_running(&self.home, &self.process_exists) {
            return Err(ResidentServiceError::AlreadyRunning);
        }
        std::fs::create_dir_all(paths.pid_url.parent().unwrap()).map_err(|_| ResidentServiceError::ModelUnavailable)?;
        let pid = std::process::id().to_string();
        std::fs::write(&paths.pid_url, &pid).map_err(|_| ResidentServiceError::ModelUnavailable)?;
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&paths.pid_url, std::fs::Permissions::from_mode(0o600));
        }
        Diagnostics::new(&self.home)
            .record_error("daemon", "model_unavailable", message)
            .map_err(|_| ResidentServiceError::ModelUnavailable)?;
        state.owned_pid = Some(pid);
        state.running = true;
        state.intentional_stop.store(false, std::sync::atomic::Ordering::SeqCst);
        state.remove_pid_on_clear = true;
        state.server = None;
        state.daemon = None;
        Ok(())
    }

    /// 프로세스 내 데몬을 멈추고 소켓을 닫는다.
    /// `remove_pid`가 true(기본)면 호스트 pid 파일을 지운다(전체 종료/헤드리스 데몬 종료).
    /// false면 pid를 남겨 Diagnostics가 여전히 살아있는 호스트로 본다(메뉴 Stop처럼 프로세스는 계속됨).
    pub fn stop(&self, remove_pid: bool) {
        let (daemon, thread, home) = {
            let mut state = self.state.lock().unwrap();
            if !state.running {
                return;
            }
            state.intentional_stop.store(true, std::sync::atomic::Ordering::SeqCst);
            state.remove_pid_on_clear = remove_pid;
            (state.daemon.clone(), state.run_thread.take(), self.home.clone())
        };
        if let Some(daemon) = daemon {
            daemon.shutdown();
        }
        if let Some(thread) = thread {
            let _ = thread.join();
        }
        Self::clear_state_if_owned_locked(&self.state, &home);
    }

    pub fn wait_until_stopped(&self) {
        while self.is_running() {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    fn clear_state_if_owned_locked(state_mutex: &Mutex<ResidentState<B, A>>, home: &Path) {
        let mut state = state_mutex.lock().unwrap();
        if !state.running {
            return;
        }
        let paths = DebriefPaths::for_home(home);
        // accept 루프를 release 전에 닫아 클라이언트가 빠르게 실패하고 deinit이 노드를 unlink하게 한다.
        if let Some(server) = &state.server {
            server.request_close();
        }
        state.run_thread = None;
        state.daemon = None;
        state.server = None;
        if state.remove_pid_on_clear {
            if let Some(owned_pid) = &state.owned_pid {
                if std::fs::read_to_string(&paths.pid_url).ok().as_deref() == Some(owned_pid.as_str()) {
                    let _ = std::fs::remove_file(&paths.pid_url);
                }
            }
            // 살아있는 accept 루프 없이 남은 소켓은 훅을 혼란시킨다(connect는 되는데 ACK가 없음).
            Self::remove_owned_socket_if_present(&paths.socket_url);
        }
        state.owned_pid = None;
        state.running = false;
        state.remove_pid_on_clear = true;
    }

    /// accept 루프가 끝난 뒤 이 유저가 소유한 잔여 UDS 경로를 unlink한다.
    fn remove_owned_socket_if_present(url: &Path) {
        let Ok(path_cstr) = std::ffi::CString::new(url.as_os_str().to_str().unwrap_or("")) else { return };
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: `path_cstr`/`info` are valid for this lstat call.
        if unsafe { libc::lstat(path_cstr.as_ptr(), &mut info) } != 0 {
            return;
        }
        // SAFETY: geteuid takes no arguments and cannot fail.
        if (info.st_mode & libc::S_IFMT) != libc::S_IFSOCK || info.st_uid != unsafe { libc::geteuid() } {
            return;
        }
        // SAFETY: `path_cstr` is valid for this call; failure is intentionally ignored.
        unsafe { libc::unlink(path_cstr.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tts_backend::{PcmBuffer, TtsBackendError};
    use std::time::Duration;

    struct RecordingBackend;
    impl TtsBackend for RecordingBackend {
        fn synthesize(&self, _text: &str, _voice: &str, _speed: f64) -> Result<PcmBuffer, TtsBackendError> {
            Ok(PcmBuffer { sample_rate: 44_100.0, channels: 1, samples: vec![0.0] })
        }
    }

    struct RecordingAudio;
    impl AudioPlaying for RecordingAudio {
        fn play(&self, _buffer: &PcmBuffer, _gain: f64) -> Result<(), crate::audio_player::AudioPlayerError> {
            Ok(())
        }
        fn stop(&self) {}
    }

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = PathBuf::from("/tmp").join(format!("cr-{nanos}-{counter}"));
        std::fs::create_dir_all(&url).unwrap();
        url
    }

    fn service_with_home_provider(home: PathBuf) -> ResidentService<RecordingBackend, RecordingAudio> {
        let provider_home = home.clone();
        ResidentService::new(
            home,
            Box::new(move |_paths| Ok(provider_home.clone())),
            Box::new(|_dir| Ok(RecordingBackend)),
            Box::new(|| RecordingAudio),
            None,
            None,
        )
    }

    #[test]
    fn start_then_stop_clears_socket_and_pid() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(&paths.models_directory).unwrap();

        let service = service_with_home_provider(home.clone());

        service.start().unwrap();
        assert!(service.is_running());
        assert!(paths.socket_url.exists());
        assert!(paths.pid_url.exists());

        service.stop(true);
        assert!(!service.is_running());
        assert!(!paths.socket_url.exists());
        assert!(!paths.pid_url.exists());

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn stop_keeping_pid_leaves_host_pid_clears_socket() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(&paths.models_directory).unwrap();

        let service = service_with_home_provider(home.clone());

        service.start().unwrap();
        assert!(service.is_running());
        assert!(paths.pid_url.exists());
        assert!(paths.socket_url.exists());

        // 메뉴 Stop: 호스트 프로세스는 계속된다 — pid는 남기고 소켓만 지운다.
        service.stop(false);
        assert!(!service.is_running());
        assert!(paths.pid_url.exists());
        assert!(!paths.socket_url.exists());

        // 같은 프로세스에서 재시작도 동작한다.
        service.start().unwrap();
        assert!(service.is_running());
        assert!(paths.socket_url.exists());
        service.stop(true);
        assert!(!paths.pid_url.exists());

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn park_without_socket_records_the_error_and_skips_the_socket() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        let service = ResidentService::new(
            home.clone(),
            Box::new(|_paths| Err(ProvisioningFailed)),
            Box::new(|_dir| Ok(RecordingBackend)),
            Box::new(|| RecordingAudio),
            None,
            None,
        );

        assert_eq!(service.start(), Err(ResidentServiceError::ModelUnavailable));
        assert!(!paths.socket_url.exists());
        service.park_without_socket("모델을 사용할 수 없습니다.").unwrap();
        assert!(service.is_running());
        assert!(paths.pid_url.exists());
        assert!(!paths.socket_url.exists());
        assert_eq!(Diagnostics::new(&home).current_error().unwrap().code, "model_unavailable");
        service.stop(true);
        assert!(!paths.pid_url.exists());

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn double_start_throws_already_running() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(&paths.models_directory).unwrap();
        let service = service_with_home_provider(home.clone());

        service.start().unwrap();
        assert_eq!(service.start(), Err(ResidentServiceError::AlreadyRunning));
        service.stop(true);

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn foreign_live_pid_without_socket_throws_already_running() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(paths.pid_url.parent().unwrap()).unwrap();
        // 메뉴 Stop 뒤 다른 호스트를 흉내낸다: 살아있는 pid, 소켓 없음.
        std::fs::write(&paths.pid_url, "4242").unwrap();
        assert!(!paths.socket_url.exists());

        let provider_home = home.clone();
        let service: ResidentService<RecordingBackend, RecordingAudio> = ResidentService::new(
            home.clone(),
            Box::new(move |_paths| Ok(provider_home.clone())),
            Box::new(|_dir| Ok(RecordingBackend)),
            Box::new(|| RecordingAudio),
            None,
            Some(Box::new(|pid| pid == 4242)),
        );

        assert_eq!(service.start(), Err(ResidentServiceError::AlreadyRunning));

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn wait_until_stopped_unblocks_after_stop() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(&paths.models_directory).unwrap();
        let service = Arc::new(service_with_home_provider(home.clone()));

        service.start().unwrap();
        assert!(service.is_running());

        let waiter_service = service.clone();
        let waiter = std::thread::spawn(move || waiter_service.wait_until_stopped());
        std::thread::sleep(Duration::from_millis(50));
        service.stop(true);
        waiter.join().unwrap();
        assert!(!service.is_running());
        assert_eq!(service.consume_run_failure(), None);

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn wait_until_stopped_unblocks_on_run_failure_and_surfaces_error() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        std::fs::create_dir_all(&paths.models_directory).unwrap();

        let held_server: Arc<Mutex<Option<Arc<UnixSocketServer>>>> = Arc::new(Mutex::new(None));
        let held_server_for_factory = held_server.clone();
        let provider_home = home.clone();
        let service: ResidentService<RecordingBackend, RecordingAudio> = ResidentService::new(
            home.clone(),
            Box::new(move |_paths| Ok(provider_home.clone())),
            Box::new(|_dir| Ok(RecordingBackend)),
            Box::new(|| RecordingAudio),
            Some(Box::new(move |url| {
                let server = Arc::new(UnixSocketServer::new(url.to_path_buf())?);
                *held_server_for_factory.lock().unwrap() = Some(server.clone());
                Ok(server)
            })),
            None,
        );
        service.start().unwrap();
        assert!(service.is_running());

        let service = Arc::new(service);
        let waiter_service = service.clone();
        let waiter = std::thread::spawn(move || waiter_service.wait_until_stopped());
        std::thread::sleep(Duration::from_millis(50));
        // intentional stop 없이 accept 소스를 닫는다 — 실행 루프가 에러로 죽는다.
        if let Some(server) = held_server.lock().unwrap().as_ref() {
            server.request_close();
        }
        waiter.join().unwrap();
        assert!(!service.is_running());

        let failure = service.consume_run_failure();
        assert!(failure.is_some());
        assert_eq!(failure, Some(DebriefDaemonError::Accept(UnixSocketError::Disconnected)));
        assert_eq!(service.consume_run_failure(), None);

        std::fs::remove_dir_all(&home).ok();
    }
}
