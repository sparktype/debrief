// 실행 파일·모델·호스트 배선·LaunchAgent를 하나의 install/start/stop/uninstall로 묶는다
use crate::diagnostics::Diagnostics;
use crate::embedded_templates::EmbeddedTemplates;
use crate::hook_event::HostSource;
use crate::host_installer::{HostInstallResult, HostInstaller};
use crate::install_manifest::{InstallManifest, InstallerDigest, OwnedRuntimeFile};
use crate::launch_agent_control::{LaunchAgentControl, LaunchctlError, LaunchctlRunning};
use crate::model_installer::InstalledModel;
use crate::paths::DebriefPaths;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

/// LaunchAgent가 없다는 사용자 메시지 — CLI 메시지 전체 집합이 포팅되면 `DebriefCommand`의
/// `CliMessages`로 옮긴다.
pub const LAUNCH_AGENT_MISSING_MESSAGE: &str = "LaunchAgent가 없습니다. debrief install을 실행하세요.";
pub const EXECUTABLE_PATH_IS_DIRECTORY_MESSAGE: &str =
    "실행 파일 경로가 디렉터리입니다. ~/.local/bin/debrief 를 비운 뒤 다시 설치하세요.";

pub trait RuntimeModelInstalling {
    fn install(&self, repair: bool) -> Result<InstalledModel, crate::model_installer::ModelInstallerError>;
}

impl<D: crate::model_installer::ModelDownloading> RuntimeModelInstalling for crate::model_installer::ModelInstaller<D> {
    fn install(&self, repair: bool) -> Result<InstalledModel, crate::model_installer::ModelInstallerError> {
        crate::model_installer::ModelInstaller::install(self, repair)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceStartResult {
    Started,
    AlreadyRunning,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RuntimeInstallerError {
    LaunchctlFailed(i32),
    AtomicExecutableReplacementFailed,
    ExecutablePathIsDirectory,
    LaunchAgentMissing,
    Io,
}

impl RuntimeInstallerError {
    pub fn description(&self) -> String {
        match self {
            RuntimeInstallerError::LaunchctlFailed(status) => format!("launchctl failed ({status})"),
            RuntimeInstallerError::AtomicExecutableReplacementFailed => "실행 파일을 바꾸지 못했습니다.".to_string(),
            RuntimeInstallerError::ExecutablePathIsDirectory => EXECUTABLE_PATH_IS_DIRECTORY_MESSAGE.to_string(),
            RuntimeInstallerError::LaunchAgentMissing => LAUNCH_AGENT_MISSING_MESSAGE.to_string(),
            RuntimeInstallerError::Io => "입출력 오류가 발생했습니다.".to_string(),
        }
    }
}

impl From<LaunchctlError> for RuntimeInstallerError {
    fn from(value: LaunchctlError) -> Self {
        match value {
            LaunchctlError::LaunchctlFailed(status) => RuntimeInstallerError::LaunchctlFailed(status),
            LaunchctlError::SpawnFailed => RuntimeInstallerError::LaunchctlFailed(-1),
        }
    }
}

pub struct RuntimeInstaller<'a, M: RuntimeModelInstalling> {
    home: PathBuf,
    source_executable: PathBuf,
    model_installer: M,
    launchctl: &'a dyn LaunchctlRunning,
    user_id: u32,
}

impl<'a, M: RuntimeModelInstalling> RuntimeInstaller<'a, M> {
    pub fn new(
        home: PathBuf,
        source_executable: PathBuf,
        model_installer: M,
        launchctl: &'a dyn LaunchctlRunning,
        user_id: u32,
    ) -> Self {
        RuntimeInstaller { home, source_executable, model_installer, launchctl, user_id }
    }

    pub fn install(&self, hosts: &HashSet<HostSource>, repair: bool) -> Result<HostInstallResult, RuntimeInstallerError> {
        let paths = DebriefPaths::for_home(&self.home);
        let previous_executable = fs::read(&paths.executable_url).ok();
        self.install_executable(&self.source_executable, &paths.executable_url)?;
        self.model_installer.install(repair).map_err(|_| RuntimeInstallerError::Io)?;
        let host_result = HostInstaller::new(self.home.clone(), paths.executable_url.clone(), None)
            .install(hosts)
            .map_err(|_| RuntimeInstallerError::Io)?;
        let launch_agent_data = EmbeddedTemplates::launch_agent(&paths.executable_url);
        let executable_changed = previous_executable.as_deref() != fs::read(&paths.executable_url).ok().as_deref();
        let plist_changed = fs::read(&paths.launch_agent_url).ok().as_deref() != Some(launch_agent_data.as_bytes());
        // 바이트가 같아도 plist를 다시 쓰면 mtime이 바뀌고, macOS Background Task Management는
        // 로그인 항목의 plist mtime이 바뀔 때마다 재스캔한다. install을 반복 실행하면(루프 등)
        // BTM 자체의 알림 속도 제한에 걸려 `launchctl bootstrap`이 EIO로 실패한다. 바뀐 게
        // 없으면 재작성과 bootout/bootstrap 재등록을 모두 건너뛴다.
        if plist_changed {
            crate::install_manifest::AtomicInstallerFile::write(launch_agent_data.as_bytes(), &paths.launch_agent_url, 0o600)
                .map_err(|_| RuntimeInstallerError::Io)?;
        }
        self.record_runtime_ownership(&paths)?;
        if executable_changed || plist_changed || !self.is_agent_healthy() {
            self.bootstrap_launch_agent(&paths)?;
        }
        Ok(host_result)
    }

    fn is_agent_healthy(&self) -> bool {
        let snapshot = Diagnostics::new(&self.home).status();
        matches!(snapshot.process, crate::diagnostics::DaemonProcessState::Running) && snapshot.socket_present
    }

    /// 기존 LaunchAgent를 활성화한다. plist를 쓰거나 config.json을 바꾸지 않는다.
    pub fn start(&self) -> Result<ServiceStartResult, RuntimeInstallerError> {
        let paths = DebriefPaths::for_home(&self.home);
        if !paths.launch_agent_url.exists() {
            return Err(RuntimeInstallerError::LaunchAgentMissing);
        }
        if matches!(Diagnostics::new(&self.home).status().process, crate::diagnostics::DaemonProcessState::Running) {
            return Ok(ServiceStartResult::AlreadyRunning);
        }
        self.bootstrap_launch_agent(&paths)?;
        Ok(ServiceStartResult::Started)
    }

    /// 에이전트를 비활성화하고 부트아웃한다. plist와 실행 파일은 유지한다.
    pub fn stop(&self) -> Result<(), RuntimeInstallerError> {
        self.disable_and_bootout()
    }

    /// enable, 이전 작업 bootout, 그다음 bootstrap. bootstrap I/O 경쟁 시 한 번 재시도한다.
    fn bootstrap_launch_agent(&self, paths: &DebriefPaths) -> Result<(), RuntimeInstallerError> {
        let domain = format!("gui/{}", self.user_id);
        let service = format!("{domain}/com.debrief.tts");
        // 메뉴 종료는 KeepAlive가 재기동하지 않도록 에이전트를 disable한다 — install에서 재활성화.
        self.launchctl.run(&LaunchAgentControl::enable_arguments(self.user_id), true)?;
        self.launchctl.run(&["bootout".to_string(), service.clone()], true)?;
        let bootstrap_args = vec!["bootstrap".to_string(), domain.clone(), paths.launch_agent_url.to_string_lossy().to_string()];
        if self.launchctl.run(&bootstrap_args, false).is_err() {
            // 살아있는 에이전트를 동시에 교체하면 EIO가 한 번 날 수 있다 — bootout 후 재시도.
            self.launchctl.run(&["bootout".to_string(), service], true)?;
            std::thread::sleep(std::time::Duration::from_millis(300));
            self.launchctl.run(&LaunchAgentControl::enable_arguments(self.user_id), true)?;
            self.launchctl.run(&bootstrap_args, false)?;
        }
        Ok(())
    }

    pub fn uninstall(&self, hosts: &HashSet<HostSource>) -> Result<HostInstallResult, RuntimeInstallerError> {
        let paths = DebriefPaths::for_home(&self.home);
        let mut manifest = InstallManifest::load(&paths.install_manifest_url).map_err(|_| RuntimeInstallerError::Io)?;
        let host_result =
            HostInstaller::new(self.home.clone(), paths.executable_url.clone(), None).uninstall(hosts).map_err(|_| RuntimeInstallerError::Io)?;
        let mut preserved = host_result.preserved_modified_files;
        self.disable_and_bootout()?;
        let removable = [paths.launch_agent_url.clone(), paths.executable_url.clone()];
        for url in &removable {
            let Some(owned) = manifest.runtime_files.iter().find(|f| Path::new(&f.path) == url.as_path()) else { continue };
            if !url.exists() || url.is_dir() {
                continue;
            }
            let Ok(data) = fs::read(url) else { continue };
            let digest = InstallerDigest::data(&data);
            if digest == owned.sha256 {
                fs::remove_file(url).ok();
            } else {
                preserved.push(url.to_string_lossy().to_string());
            }
        }
        manifest.runtime_files.retain(|owned| !removable.iter().any(|url| url.as_path() == Path::new(&owned.path)));
        manifest.save(&paths.install_manifest_url).map_err(|_| RuntimeInstallerError::Io)?;
        preserved.sort();
        Ok(HostInstallResult { codex_review_required: false, preserved_modified_files: preserved })
    }

    fn disable_and_bootout(&self) -> Result<(), RuntimeInstallerError> {
        self.launchctl.run(&LaunchAgentControl::disable_arguments(self.user_id), true)?;
        self.launchctl.run(&LaunchAgentControl::bootout_arguments(self.user_id), true)?;
        Ok(())
    }

    fn install_executable(&self, source: &Path, destination: &Path) -> Result<(), RuntimeInstallerError> {
        use std::os::unix::fs::PermissionsExt;

        if destination.is_dir() {
            return Err(RuntimeInstallerError::ExecutablePathIsDirectory);
        }
        let canonical_source = fs::canonicalize(source).unwrap_or_else(|_| source.to_path_buf());
        let canonical_destination = fs::canonicalize(destination).unwrap_or_else(|_| destination.to_path_buf());
        if canonical_source == canonical_destination {
            fs::set_permissions(destination, fs::Permissions::from_mode(0o755))
                .map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
            return Ok(());
        }

        let directory = destination.parent().expect("executable destination must have a parent directory");
        fs::create_dir_all(directory).map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
        let temporary = directory.join(format!(".debrief.{}.tmp", std::process::id()));
        fs::copy(source, &temporary).map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))
            .map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
        {
            let file = fs::File::open(&temporary).map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
            file.sync_all().map_err(|_| RuntimeInstallerError::AtomicExecutableReplacementFailed)?;
        }

        if destination.exists() {
            // SAFETY: path_cstr produces valid null-terminated C strings from UTF-8 paths;
            // both `temporary` and `destination` are absolute paths, so AT_FDCWD is unused.
            let swapped = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    Self::path_cstr(&temporary).as_ptr(),
                    libc::AT_FDCWD,
                    Self::path_cstr(destination).as_ptr(),
                    libc::RENAME_SWAP,
                )
            };
            if swapped != 0 {
                let _ = fs::remove_file(&temporary);
                return Err(RuntimeInstallerError::AtomicExecutableReplacementFailed);
            }
            let _ = fs::remove_file(&temporary);
        } else if fs::rename(&temporary, destination).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(RuntimeInstallerError::AtomicExecutableReplacementFailed);
        }
        Ok(())
    }

    fn record_runtime_ownership(&self, paths: &DebriefPaths) -> Result<(), RuntimeInstallerError> {
        let mut manifest = InstallManifest::load(&paths.install_manifest_url).map_err(|_| RuntimeInstallerError::Io)?;
        let urls = [paths.executable_url.clone(), paths.launch_agent_url.clone()];
        manifest.runtime_files.retain(|owned| !urls.iter().any(|url| url.as_path() == Path::new(&owned.path)));
        for url in &urls {
            let data = fs::read(url).map_err(|_| RuntimeInstallerError::Io)?;
            manifest.runtime_files.push(OwnedRuntimeFile { path: url.to_string_lossy().to_string(), sha256: InstallerDigest::data(&data) });
        }
        manifest.save(&paths.install_manifest_url).map_err(|_| RuntimeInstallerError::Io)
    }

    fn path_cstr(path: &Path) -> std::ffi::CString {
        std::ffi::CString::new(path.as_os_str().to_str().unwrap()).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct EventLog {
        values: Mutex<Vec<String>>,
    }
    impl EventLog {
        fn new() -> Self {
            EventLog { values: Mutex::new(Vec::new()) }
        }
        fn append(&self, value: &str) {
            self.values.lock().unwrap().push(value.to_string());
        }
        fn values(&self) -> Vec<String> {
            self.values.lock().unwrap().clone()
        }
    }

    struct FakeRuntimeModelInstaller<'a> {
        events: &'a EventLog,
        directory: PathBuf,
        installed_executable: Option<PathBuf>,
    }
    impl<'a> RuntimeModelInstalling for FakeRuntimeModelInstaller<'a> {
        fn install(&self, repair: bool) -> Result<InstalledModel, crate::model_installer::ModelInstallerError> {
            if let Some(installed_executable) = &self.installed_executable {
                if !installed_executable.exists() {
                    self.events.append("model-before-binary");
                }
            }
            self.events.append(&format!("model:{repair}"));
            Ok(InstalledModel { revision: "a".repeat(40), directory: self.directory.clone() })
        }
    }

    struct FakeLaunchctlRunner<'a> {
        events: &'a EventLog,
        executable_to_observe: Option<PathBuf>,
        fail_bootstrap: bool,
    }
    impl<'a> LaunchctlRunning for FakeLaunchctlRunner<'a> {
        fn run(&self, arguments: &[String], _allow_failure: bool) -> Result<(), LaunchctlError> {
            match arguments.first().map(|s| s.as_str()) {
                Some("bootout") => {
                    let suffix = match &self.executable_to_observe {
                        Some(path) if path.exists() => ":binary-present",
                        Some(_) => ":binary-missing",
                        None => "",
                    };
                    self.events.append(&format!("bootout{suffix}"));
                }
                Some("bootstrap") => {
                    self.events.append("bootstrap");
                    if self.fail_bootstrap {
                        return Err(LaunchctlError::LaunchctlFailed(1));
                    }
                }
                Some("enable") => self.events.append("enable"),
                Some("disable") => self.events.append("disable"),
                _ => {}
            }
            Ok(())
        }
    }

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = std::env::temp_dir().join(format!("debrief-runtime-tests-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    #[test]
    fn install_copies_binary_before_model_and_bootstraps_idempotently() {
        let home = temporary_home();
        let source = home.join("build/debrief");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "binary").unwrap();
        let paths = DebriefPaths::for_home(&home);
        let events = EventLog::new();
        let model = FakeRuntimeModelInstaller {
            events: &events,
            directory: home.join("model"),
            installed_executable: Some(paths.executable_url.clone()),
        };
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let installer = RuntimeInstaller::new(home.clone(), source, model, &launchctl, 501);

        installer.install(&HashSet::new(), true).unwrap();
        installer.install(&HashSet::new(), true).unwrap();

        let installed = &paths.executable_url;
        assert!(installed.to_string_lossy().ends_with("/.local/bin/debrief"));
        assert_eq!(fs::read(installed).unwrap(), b"binary");
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(installed).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755);
        let recorded = events.values();
        assert_eq!(
            recorded,
            vec!["model:true", "enable", "bootout", "bootstrap", "model:true", "enable", "bootout", "bootstrap"]
        );
        assert!(!recorded.contains(&"model-before-binary".to_string()));
        let plist = fs::read_to_string(&paths.launch_agent_url).unwrap();
        assert!(plist.contains(&installed.to_string_lossy().to_string()));
        assert!(plist.contains("daemon"));
        assert!(!plist.contains("AssociatedBundleIdentifiers"));
        let manifest = InstallManifest::load(&paths.install_manifest_url).unwrap();
        assert!(manifest.runtime_files.iter().any(|f| f.path == installed.to_string_lossy()));
        assert!(!manifest.runtime_files.iter().any(|f| f.path.contains(".app")));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_skips_bootstrap_when_agent_is_already_healthy_and_unchanged() {
        let home = temporary_home();
        let source = home.join("build/debrief");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "binary").unwrap();
        let paths = DebriefPaths::for_home(&home);
        let events = EventLog::new();
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.join("model"), installed_executable: None };
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let installer = RuntimeInstaller::new(home.clone(), source, model, &launchctl, 501);

        installer.install(&HashSet::new(), true).unwrap();

        fs::create_dir_all(paths.pid_url.parent().unwrap()).unwrap();
        fs::write(&paths.pid_url, std::process::id().to_string()).unwrap();
        fs::write(&paths.socket_url, "socket").unwrap();

        installer.install(&HashSet::new(), true).unwrap();

        assert_eq!(events.values(), vec!["model:true", "enable", "bootout", "bootstrap", "model:true"]);

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn uninstall_boots_out_before_removing_executable() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.executable_url.parent().unwrap()).unwrap();
        fs::write(&paths.executable_url, "binary").unwrap();
        InstallManifest {
            hooks: Vec::new(),
            files: Vec::new(),
            runtime_files: vec![OwnedRuntimeFile {
                path: paths.executable_url.to_string_lossy().to_string(),
                sha256: InstallerDigest::data(b"binary"),
            }],
        }
        .save(&paths.install_manifest_url)
        .unwrap();
        let events = EventLog::new();
        let launchctl =
            FakeLaunchctlRunner { events: &events, executable_to_observe: Some(paths.executable_url.clone()), fail_bootstrap: false };
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.clone(), installed_executable: None };
        let installer = RuntimeInstaller::new(home.clone(), paths.executable_url.clone(), model, &launchctl, 501);

        installer.uninstall(&HashSet::new()).unwrap();

        assert_eq!(events.values(), vec!["disable", "bootout:binary-present"]);
        assert!(!paths.executable_url.exists());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn uninstall_keeps_executable_when_digest_differs() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.executable_url.parent().unwrap()).unwrap();
        fs::write(&paths.executable_url, "user-binary").unwrap();
        InstallManifest {
            hooks: Vec::new(),
            files: Vec::new(),
            runtime_files: vec![OwnedRuntimeFile { path: paths.executable_url.to_string_lossy().to_string(), sha256: "0".repeat(64) }],
        }
        .save(&paths.install_manifest_url)
        .unwrap();

        let events = EventLog::new();
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.clone(), installed_executable: None };
        let result = RuntimeInstaller::new(home.clone(), paths.executable_url.clone(), model, &launchctl, 501)
            .uninstall(&HashSet::new())
            .unwrap();

        assert_eq!(fs::read(&paths.executable_url).unwrap(), b"user-binary");
        assert_eq!(result.preserved_modified_files, vec![paths.executable_url.to_string_lossy().to_string()]);

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn uninstall_preserves_modified_launch_agent() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "user modified plist").unwrap();
        InstallManifest {
            hooks: Vec::new(),
            files: Vec::new(),
            runtime_files: vec![OwnedRuntimeFile { path: paths.launch_agent_url.to_string_lossy().to_string(), sha256: "0".repeat(64) }],
        }
        .save(&paths.install_manifest_url)
        .unwrap();

        let events = EventLog::new();
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.clone(), installed_executable: None };
        let result = RuntimeInstaller::new(home.clone(), paths.executable_url.clone(), model, &launchctl, 501)
            .uninstall(&HashSet::new())
            .unwrap();

        assert_eq!(fs::read(&paths.launch_agent_url).unwrap(), b"user modified plist");
        assert_eq!(result.preserved_modified_files, vec![paths.launch_agent_url.to_string_lossy().to_string()]);

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_refuses_an_executable_directory() {
        let blocked = temporary_home();
        let destination = DebriefPaths::for_home(&blocked).executable_url;
        fs::create_dir_all(&destination).unwrap();
        fs::write(destination.join("child"), "keep").unwrap();
        let blocked_source = blocked.join("build/debrief");
        fs::create_dir_all(blocked_source.parent().unwrap()).unwrap();
        fs::write(&blocked_source, "binary").unwrap();
        let events = EventLog::new();
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let model = FakeRuntimeModelInstaller { events: &events, directory: blocked.clone(), installed_executable: None };
        let blocked_installer = RuntimeInstaller::new(blocked.clone(), blocked_source, model, &launchctl, 501);

        let result = blocked_installer.install(&HashSet::new(), true);

        assert_eq!(result, Err(RuntimeInstallerError::ExecutablePathIsDirectory));
        assert!(destination.join("child").exists());
        assert_eq!(RuntimeInstallerError::ExecutablePathIsDirectory.description(), EXECUTABLE_PATH_IS_DIRECTORY_MESSAGE);

        fs::remove_dir_all(&blocked).ok();
    }

    #[test]
    fn failed_bootstrap_throws() {
        let home = temporary_home();
        let source = home.join("build/debrief");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "binary").unwrap();
        let events = EventLog::new();
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: true };
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.clone(), installed_executable: None };
        let installer = RuntimeInstaller::new(home.clone(), source, model, &launchctl, 501);

        let result = installer.install(&HashSet::new(), true);
        assert!(result.is_err());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn start_refuses_missing_plist_and_a_running_process() {
        let home = temporary_home();
        let paths = DebriefPaths::for_home(&home);
        crate::configuration::DebriefConfiguration {
            mode: crate::configuration::DebriefMode::Focus,
            muted: false,
            ..Default::default()
        }
        .save(&paths.config_url)
        .unwrap();
        let config_before = fs::read(&paths.config_url).unwrap();
        let events = EventLog::new();
        let launchctl = FakeLaunchctlRunner { events: &events, executable_to_observe: None, fail_bootstrap: false };
        let model = FakeRuntimeModelInstaller { events: &events, directory: home.clone(), installed_executable: None };
        let installer = RuntimeInstaller::new(home.clone(), paths.executable_url.clone(), model, &launchctl, 501);

        assert_eq!(installer.start(), Err(RuntimeInstallerError::LaunchAgentMissing));
        assert_eq!(fs::read(&paths.config_url).unwrap(), config_before);

        fs::create_dir_all(paths.launch_agent_url.parent().unwrap()).unwrap();
        fs::write(&paths.launch_agent_url, "plist").unwrap();
        fs::create_dir_all(paths.pid_url.parent().unwrap()).unwrap();
        fs::write(&paths.pid_url, std::process::id().to_string()).unwrap();
        let events2 = EventLog::new();
        let launchctl2 = FakeLaunchctlRunner { events: &events2, executable_to_observe: None, fail_bootstrap: false };
        let model2 = FakeRuntimeModelInstaller { events: &events2, directory: home.clone(), installed_executable: None };
        let running = RuntimeInstaller::new(home.clone(), paths.executable_url.clone(), model2, &launchctl2, 501);
        assert_eq!(running.start(), Ok(ServiceStartResult::AlreadyRunning));
        assert!(events2.values().is_empty());

        fs::remove_dir_all(&home).ok();
    }
}
