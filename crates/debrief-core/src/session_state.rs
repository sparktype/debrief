// 세션별 프로젝트 레이블·턴 시작 시각·발화 여부를 훅/MCP 프로세스가 공유하는 상태 저장소
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// 이 시간(초) 안에 본 다른 프로젝트 세션이 있으면 다중 세션으로 본다.
const ACTIVE_WINDOW_SECONDS: u64 = 30 * 60;
const RETAINED_SECONDS: u64 = 24 * 60 * 60;
const RETAINED_SESSION_LIMIT: usize = 128;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionEntry {
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub last_seen: u64,
    #[serde(default)]
    pub turn_started: Option<u64>,
    #[serde(default)]
    pub spoken: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionStates {
    #[serde(default)]
    pub sessions: HashMap<String, SessionEntry>,
}

impl SessionStates {
    pub fn touch(&mut self, session_id: &str, project: Option<String>, now: u64) {
        let entry = self.sessions.entry(session_id.to_string()).or_default();
        if project.is_some() {
            entry.project = project;
        }
        entry.last_seen = now;
    }

    pub fn begin_turn(&mut self, session_id: &str, now: u64) {
        let entry = self.sessions.entry(session_id.to_string()).or_default();
        entry.turn_started = Some(now);
        entry.spoken = false;
    }

    pub fn mark_spoken(&mut self, session_id: &str) {
        if let Some(entry) = self.sessions.get_mut(session_id) {
            entry.spoken = true;
        }
    }

    /// 턴을 마무리하고 (경과 초, 에이전트가 이미 말했는지)를 돌려준다. 시작 기록이 없으면 `None`.
    pub fn finish_turn(&mut self, session_id: &str, now: u64) -> Option<(u64, bool)> {
        let entry = self.sessions.get_mut(session_id)?;
        let started = entry.turn_started.take()?;
        let spoken = std::mem::take(&mut entry.spoken);
        Some((now.saturating_sub(started), spoken))
    }

    /// 다른 프로젝트의 세션이 최근에 활성이면 이 세션의 프로젝트 이름을 돌려준다.
    pub fn label_for(&self, session_id: &str, now: u64) -> Option<String> {
        let project = self.sessions.get(session_id)?.project.as_ref()?;
        let others_active = self.sessions.iter().any(|(id, other)| {
            id != session_id
                && now.saturating_sub(other.last_seen) <= ACTIVE_WINDOW_SECONDS
                && other.project.as_ref().is_some_and(|name| name != project)
        });
        others_active.then(|| project.clone())
    }

    fn prune(&mut self, now: u64) {
        self.sessions.retain(|_, entry| now.saturating_sub(entry.last_seen) <= RETAINED_SECONDS);
        let overflow = self.sessions.len().saturating_sub(RETAINED_SESSION_LIMIT);
        if overflow > 0 {
            let mut by_age: Vec<_> = self.sessions.iter().map(|(id, e)| (e.last_seen, id.clone())).collect();
            by_age.sort();
            for (_, id) in by_age.into_iter().take(overflow) {
                self.sessions.remove(&id);
            }
        }
    }
}

/// `cwd`에서 사용자에게 들려줄 프로젝트 이름을 뽑는다. 워크트리(`.claude/worktrees/<이름>`)면
/// 워크트리 이름이 아니라 원래 프로젝트 디렉터리 이름을 쓴다.
pub fn project_label(cwd: &str) -> Option<String> {
    let root = cwd.split("/.claude/worktrees/").next().unwrap_or(cwd);
    root.trim_end_matches('/').rsplit('/').next().filter(|name| !name.is_empty()).map(str::to_string)
}

#[derive(Debug, PartialEq, Eq)]
pub enum SessionStateError {
    Io,
}

/// `SessionStates`를 파일에 영속화한다. 읽고-수정하고-쓰는 전체를 하나의 배타 잠금 안에서 수행한다.
pub struct SessionStateStore {
    pub url: std::path::PathBuf,
}

impl SessionStateStore {
    pub fn new(url: std::path::PathBuf) -> Self {
        SessionStateStore { url }
    }

    pub fn update<R>(&self, now: u64, change: impl FnOnce(&mut SessionStates) -> R) -> Result<R, SessionStateError> {
        use std::fs;
        use std::io::{Read, Seek, SeekFrom, Write};
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        use std::os::unix::io::AsRawFd;

        let directory = self.url.parent().expect("session state url must have a parent directory");
        let directory_existed = directory.exists();
        fs::create_dir_all(directory).map_err(|_| SessionStateError::Io)?;
        if !directory_existed {
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).map_err(|_| SessionStateError::Io)?;
        }
        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&self.url)
            .map_err(|_| SessionStateError::Io)?;

        // SAFETY: `file`은 이 잠금/해제 쌍 동안 열려 있다. F_SETLKW는 파일 전체의 배타 잠금을 얻을 때까지 막는다.
        let mut lock = libc::flock { l_type: libc::F_WRLCK, l_whence: libc::SEEK_SET as i16, l_start: 0, l_len: 0, l_pid: 0 };
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLKW, &mut lock) } != 0 {
            return Err(SessionStateError::Io);
        }

        let result = (|| {
            let mut data = Vec::new();
            file.read_to_end(&mut data).map_err(|_| SessionStateError::Io)?;
            let mut states: SessionStates = serde_json::from_slice(&data).unwrap_or_default();
            let value = change(&mut states);
            states.prune(now);
            let encoded = serde_json::to_vec(&states).map_err(|_| SessionStateError::Io)?;
            file.set_len(0).map_err(|_| SessionStateError::Io)?;
            file.seek(SeekFrom::Start(0)).map_err(|_| SessionStateError::Io)?;
            file.write_all(&encoded).map_err(|_| SessionStateError::Io)?;
            Ok(value)
        })();

        lock.l_type = libc::F_UNLCK;
        // SAFETY: 위에서 잠근 같은 fd를 푼다.
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &mut lock) };
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_label_uses_directory_name_and_unwraps_worktrees() {
        assert_eq!(project_label("/Users/x/Develop/debrief").as_deref(), Some("debrief"));
        assert_eq!(project_label("/Users/x/Develop/debrief/").as_deref(), Some("debrief"));
        assert_eq!(project_label("/Users/x/Develop/debrief/.claude/worktrees/feat-a").as_deref(), Some("debrief"));
        assert_eq!(project_label("/"), None);
        assert_eq!(project_label(""), None);
    }

    #[test]
    fn label_only_when_another_project_is_recently_active() {
        let mut states = SessionStates::default();
        states.touch("a", Some("debrief".into()), 1000);
        assert_eq!(states.label_for("a", 1000), None, "혼자일 때는 붙이지 않는다");

        states.touch("b", Some("richell".into()), 1100);
        assert_eq!(states.label_for("a", 1100).as_deref(), Some("debrief"));
        assert_eq!(states.label_for("b", 1100).as_deref(), Some("richell"));

        states.touch("c", Some("debrief".into()), 1200);
        states.sessions.remove("b");
        assert_eq!(states.label_for("a", 1200), None, "같은 프로젝트 세션끼리는 구분하지 않는다");
    }

    #[test]
    fn label_ignores_stale_sessions() {
        let mut states = SessionStates::default();
        states.touch("a", Some("debrief".into()), 0);
        states.touch("b", Some("richell".into()), 0);
        assert_eq!(states.label_for("a", ACTIVE_WINDOW_SECONDS + 1), None);
    }

    #[test]
    fn finish_turn_reports_elapsed_and_spoken_once() {
        let mut states = SessionStates::default();
        states.touch("a", None, 100);
        states.begin_turn("a", 100);
        states.mark_spoken("a");
        assert_eq!(states.finish_turn("a", 190), Some((90, true)));
        assert_eq!(states.finish_turn("a", 200), None, "한 턴은 한 번만 마무리된다");

        states.begin_turn("a", 300);
        assert_eq!(states.finish_turn("a", 310), Some((10, false)), "새 턴은 spoken이 초기화된다");
    }

    #[test]
    fn mark_spoken_without_session_is_noop() {
        let mut states = SessionStates::default();
        states.mark_spoken("ghost");
        assert!(states.sessions.is_empty());
    }

    #[test]
    fn store_roundtrips_and_prunes_old_sessions() {
        let directory = std::env::temp_dir().join(format!("debrief-state-{}-{}", std::process::id(), line!()));
        let store = SessionStateStore::new(directory.join("session-state.json"));
        store.update(1000, |s| s.touch("old", Some("p".into()), 1000)).unwrap();
        store.update(1000 + RETAINED_SECONDS + 1, |s| s.touch("new", Some("q".into()), 1000 + RETAINED_SECONDS + 1)).unwrap();
        let keys = store.update(1000 + RETAINED_SECONDS + 1, |s| s.sessions.keys().cloned().collect::<Vec<_>>()).unwrap();
        assert_eq!(keys, vec!["new".to_string()]);
        std::fs::remove_dir_all(directory).ok();
    }
}
