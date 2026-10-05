use std::path::{Path, PathBuf};

/// 실행 중인 바이너리의 실제 경로. `argv[0]`는 셸이 `PATH`로 해석한 리터럴 명령일 뿐
/// 절대 경로가 아니므로, 여기서 그걸 쓰면 안 된다.
pub fn current_executable_url() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("debrief")).canonicalize().unwrap_or_else(|_| PathBuf::from("debrief"))
}

pub struct DebriefPaths {
    pub home: PathBuf,
    pub data_directory: PathBuf,
    pub cache_directory: PathBuf,
    pub config_url: PathBuf,
    pub models_directory: PathBuf,
    pub socket_url: PathBuf,
    pub decide_socket_url: PathBuf,
    pub pid_url: PathBuf,
    pub executable_url: PathBuf,
    pub launch_agent_url: PathBuf,
    pub install_manifest_url: PathBuf,
    pub last_error_url: PathBuf,
    pub session_voices_url: PathBuf,
    pub session_state_url: PathBuf,
}

impl DebriefPaths {
    pub fn for_home(home: &Path) -> Self {
        let data_directory = home.join("Library/Application Support/debrief");
        let cache_directory = home.join("Library/Caches/debrief");
        DebriefPaths {
            home: home.to_path_buf(),
            data_directory: data_directory.clone(),
            cache_directory: cache_directory.clone(),
            config_url: data_directory.join("config.json"),
            models_directory: data_directory.join("models"),
            socket_url: cache_directory.join("debrief.sock"),
            decide_socket_url: home.join(".cache/decide/decide.sock"),
            pid_url: cache_directory.join("daemon.pid"),
            executable_url: home.join(".local/bin/debrief"),
            launch_agent_url: home.join("Library/LaunchAgents/com.debrief.tts.plist"),
            install_manifest_url: data_directory.join("install-manifest.json"),
            last_error_url: cache_directory.join("last-error.json"),
            session_voices_url: data_directory.join("session-voices.json"),
            session_state_url: data_directory.join("session-state.json"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_stay_under_the_provided_home() {
        let home = PathBuf::from("/Users/example");
        let paths = DebriefPaths::for_home(&home);

        assert_eq!(paths.data_directory, PathBuf::from("/Users/example/Library/Application Support/debrief"));
        assert_eq!(paths.cache_directory, PathBuf::from("/Users/example/Library/Caches/debrief"));
        assert_eq!(paths.config_url, PathBuf::from("/Users/example/Library/Application Support/debrief/config.json"));
        assert_eq!(paths.socket_url, PathBuf::from("/Users/example/Library/Caches/debrief/debrief.sock"));
        assert_eq!(paths.decide_socket_url, PathBuf::from("/Users/example/.cache/decide/decide.sock"));
        assert_eq!(paths.launch_agent_url, PathBuf::from("/Users/example/Library/LaunchAgents/com.debrief.tts.plist"));
        assert_eq!(paths.pid_url, PathBuf::from("/Users/example/Library/Caches/debrief/daemon.pid"));
        assert_eq!(paths.last_error_url, PathBuf::from("/Users/example/Library/Caches/debrief/last-error.json"));
        assert_eq!(paths.executable_url, PathBuf::from("/Users/example/.local/bin/debrief"));
        assert_eq!(paths.install_manifest_url, PathBuf::from("/Users/example/Library/Application Support/debrief/install-manifest.json"));
        assert_eq!(paths.models_directory, PathBuf::from("/Users/example/Library/Application Support/debrief/models"));
        assert_eq!(paths.session_voices_url, PathBuf::from("/Users/example/Library/Application Support/debrief/session-voices.json"));
        assert_eq!(paths.session_state_url, PathBuf::from("/Users/example/Library/Application Support/debrief/session-state.json"));
    }
}
