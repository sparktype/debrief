// LaunchAgent 라벨·disable/enable/bootout (메뉴 종료 시 KeepAlive 재기동 방지)
//
// 종료는 작업 안에서 bootout을 기다리면 안 된다. `launchctl bootout`은 대상 프로세스가
// 끝날 때까지 기다리는데, 그 대상이 우리 자신이면 교착 상태가 된다. disable을 먼저
// 호출(실행 중인 작업에서도 블로킹 없이 안전)해 KeepAlive가 재기동하지 않게 만든 뒤
// 종료하고, 재설치 시 enable로 되돌린다.

pub trait LaunchctlRunning {
    fn run(&self, arguments: &[String], allow_failure: bool) -> Result<(), LaunchctlError>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum LaunchctlError {
    LaunchctlFailed(i32),
    SpawnFailed,
}

pub struct ProcessLaunchctlRunner;

impl ProcessLaunchctlRunner {
    pub fn new() -> Self {
        ProcessLaunchctlRunner
    }
}

impl Default for ProcessLaunchctlRunner {
    fn default() -> Self {
        Self::new()
    }
}

impl LaunchctlRunning for ProcessLaunchctlRunner {
    fn run(&self, arguments: &[String], allow_failure: bool) -> Result<(), LaunchctlError> {
        let status = std::process::Command::new("/bin/launchctl")
            .args(arguments)
            .status()
            .map_err(|_| LaunchctlError::SpawnFailed)?;
        if !allow_failure && !status.success() {
            return Err(LaunchctlError::LaunchctlFailed(status.code().unwrap_or(-1)));
        }
        Ok(())
    }
}

pub struct LaunchAgentControl;

impl LaunchAgentControl {
    pub const LABEL: &'static str = "com.debrief.tts";

    pub fn domain(user_id: u32) -> String {
        format!("gui/{user_id}")
    }

    pub fn service_target(user_id: u32) -> String {
        format!("{}/{}", Self::domain(user_id), Self::LABEL)
    }

    pub fn bootout_arguments(user_id: u32) -> Vec<String> {
        vec!["bootout".to_string(), Self::service_target(user_id)]
    }

    pub fn disable_arguments(user_id: u32) -> Vec<String> {
        vec!["disable".to_string(), Self::service_target(user_id)]
    }

    pub fn enable_arguments(user_id: u32) -> Vec<String> {
        vec!["enable".to_string(), Self::service_target(user_id)]
    }

    /// 에이전트를 disabled로 표시해 종료 후 KeepAlive가 재기동하지 않게 한다.
    /// (`bootout`과 달리) 실행 중인 작업 안에서 호출해도 안전하다.
    pub fn disable(user_id: u32, launchctl: &dyn LaunchctlRunning) -> Result<(), LaunchctlError> {
        launchctl.run(&Self::disable_arguments(user_id), true)
    }

    /// bootstrap/install이 다시 로드할 수 있도록 에이전트를 재활성화한다.
    pub fn enable(user_id: u32, launchctl: &dyn LaunchctlRunning) -> Result<(), LaunchctlError> {
        launchctl.run(&Self::enable_arguments(user_id), true)
    }

    /// 에이전트를 언로드한다. 같은 작업 안에서 기다리면 안 된다 — 교착 상태.
    pub fn bootout(user_id: u32, launchctl: &dyn LaunchctlRunning) -> Result<(), LaunchctlError> {
        launchctl.run(&Self::bootout_arguments(user_id), true)
    }

    /// 기다리지 않고 `launchctl bootout`을 시작한다(disable 후 best-effort 정리).
    pub fn bootout_detached(user_id: u32) {
        let _ = std::process::Command::new("/bin/launchctl")
            .args(Self::bootout_arguments(user_id))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct RecordingLaunchctl {
        calls: Mutex<Vec<(Vec<String>, bool)>>,
    }

    impl RecordingLaunchctl {
        fn new() -> Self {
            RecordingLaunchctl { calls: Mutex::new(Vec::new()) }
        }
    }

    impl LaunchctlRunning for RecordingLaunchctl {
        fn run(&self, arguments: &[String], allow_failure: bool) -> Result<(), LaunchctlError> {
            self.calls.lock().unwrap().push((arguments.to_vec(), allow_failure));
            Ok(())
        }
    }

    #[test]
    fn service_target_and_bootout_arguments() {
        assert_eq!(LaunchAgentControl::LABEL, "com.debrief.tts");
        assert_eq!(LaunchAgentControl::service_target(501), "gui/501/com.debrief.tts");
        assert_eq!(LaunchAgentControl::bootout_arguments(501), vec!["bootout", "gui/501/com.debrief.tts"]);
        assert_eq!(LaunchAgentControl::disable_arguments(501), vec!["disable", "gui/501/com.debrief.tts"]);
        assert_eq!(LaunchAgentControl::enable_arguments(501), vec!["enable", "gui/501/com.debrief.tts"]);
    }

    #[test]
    fn disable_invokes_launchctl_with_allow_failure() {
        let runner = RecordingLaunchctl::new();
        LaunchAgentControl::disable(42, &runner).unwrap();
        let calls = runner.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, vec!["disable", "gui/42/com.debrief.tts"]);
        assert!(calls[0].1);
    }

    #[test]
    fn enable_invokes_launchctl_with_allow_failure() {
        let runner = RecordingLaunchctl::new();
        LaunchAgentControl::enable(42, &runner).unwrap();
        let calls = runner.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, vec!["enable", "gui/42/com.debrief.tts"]);
        assert!(calls[0].1);
    }
}
