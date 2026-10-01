// 세션별 도우미 보이스 라운드로빈 — 같은 세션은 같은 보이스를 유지
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionVoiceRotation {
    #[serde(default)]
    pub next: usize,
    #[serde(default)]
    pub sessions: HashMap<String, String>,
    #[serde(default = "SessionVoiceRotation::default_order_of_claims")]
    pub order_of_claims: Vec<String>,
}

impl SessionVoiceRotation {
    pub const ORDER: [&'static str; 10] = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"];
    pub const RETAINED_SESSION_LIMIT: usize = 128;

    fn default_order_of_claims() -> Vec<String> {
        Vec::new()
    }

    pub fn new() -> Self {
        SessionVoiceRotation { next: 0, sessions: HashMap::new(), order_of_claims: Vec::new() }
    }

    /// `session_id`에 저장된 보이스가 있으면 그걸 돌려주고, 없으면 `ORDER`의 다음 보이스를 할당한다.
    pub fn claim(&mut self, session_id: &str) -> String {
        if let Some(existing) = self.sessions.get(session_id) {
            return existing.clone();
        }
        let voice = Self::ORDER[self.next % Self::ORDER.len()].to_string();
        self.next += 1;
        self.sessions.insert(session_id.to_string(), voice.clone());
        self.order_of_claims.push(session_id.to_string());
        let overflow = self.order_of_claims.len().saturating_sub(Self::RETAINED_SESSION_LIMIT);
        if overflow > 0 {
            for identifier in self.order_of_claims.drain(0..overflow).collect::<Vec<_>>() {
                self.sessions.remove(&identifier);
            }
        }
        voice
    }
}

impl Default for SessionVoiceRotation {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum SessionVoiceError {
    EmptySession,
    LockFailed,
}

/// `SessionVoiceRotation`을 파일로 영속화해 훅·MCP 프로세스가 커서를 공유한다.
pub struct SessionVoiceStore {
    pub url: std::path::PathBuf,
}

impl SessionVoiceStore {
    pub fn new(url: std::path::PathBuf) -> Self {
        SessionVoiceStore { url }
    }

    pub fn claim(&self, session_id: &str) -> Result<String, SessionVoiceError> {
        use std::fs;
        use std::io::{Read, Seek, SeekFrom, Write};
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::io::AsRawFd;

        let identifier = session_id.trim();
        if identifier.is_empty() {
            return Err(SessionVoiceError::EmptySession);
        }

        let directory = self.url.parent().expect("session voices url must have a parent directory");
        let directory_existed = directory.exists();
        fs::create_dir_all(directory).map_err(|_| SessionVoiceError::LockFailed)?;
        if !directory_existed {
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
                .map_err(|_| SessionVoiceError::LockFailed)?;
        }
        if !self.url.exists() {
            fs::write(&self.url, b"{}").map_err(|_| SessionVoiceError::LockFailed)?;
            fs::set_permissions(&self.url, fs::Permissions::from_mode(0o600))
                .map_err(|_| SessionVoiceError::LockFailed)?;
        }

        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&self.url)
            .map_err(|_| SessionVoiceError::LockFailed)?;

        // SAFETY: `file` stays open and valid for the lifetime of this lock/unlock pair;
        // F_SETLKW blocks until an exclusive advisory lock on the whole file is acquired.
        let mut lock = libc::flock {
            l_type: libc::F_WRLCK,
            l_whence: libc::SEEK_SET as i16,
            l_start: 0,
            l_len: 0,
            l_pid: 0,
        };
        let locked = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLKW, &mut lock) };
        if locked != 0 {
            return Err(SessionVoiceError::LockFailed);
        }

        let result = (|| -> Result<String, SessionVoiceError> {
            let mut data = Vec::new();
            file.read_to_end(&mut data).map_err(|_| SessionVoiceError::LockFailed)?;
            let mut state: SessionVoiceRotation =
                serde_json::from_slice(&data).unwrap_or_else(|_| SessionVoiceRotation::new());
            let voice = state.claim(identifier);
            let encoded = serde_json::to_vec(&state).map_err(|_| SessionVoiceError::LockFailed)?;
            file.seek(SeekFrom::Start(0)).map_err(|_| SessionVoiceError::LockFailed)?;
            file.write_all(&encoded).map_err(|_| SessionVoiceError::LockFailed)?;
            file.set_len(encoded.len() as u64).map_err(|_| SessionVoiceError::LockFailed)?;
            Ok(voice)
        })();

        // SAFETY: same `file` descriptor as above, releasing the lock taken earlier.
        let mut unlock = libc::flock {
            l_type: libc::F_UNLCK,
            l_whence: libc::SEEK_SET as i16,
            l_start: 0,
            l_len: 0,
            l_pid: 0,
        };
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &mut unlock) };

        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voice_catalog::VoiceCatalog;

    #[test]
    fn walks_every_voice_then_wraps() {
        let mut state = SessionVoiceRotation::new();
        let mut heard = Vec::new();
        for index in 0..SessionVoiceRotation::ORDER.len() {
            heard.push(state.claim(&format!("session-{index}")));
        }
        assert_eq!(heard, SessionVoiceRotation::ORDER.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(state.claim("session-wrap"), "F1");
        let order_set: std::collections::HashSet<_> =
            SessionVoiceRotation::ORDER.iter().map(|s| s.to_string()).collect();
        assert_eq!(&order_set, VoiceCatalog::allowed_voice_ids());
    }

    #[test]
    fn same_session_keeps_its_voice() {
        let mut state = SessionVoiceRotation::new();
        assert_eq!(state.claim("alpha"), "F1");
        assert_eq!(state.claim("beta"), "F2");
        assert_eq!(state.claim("alpha"), "F1");
        assert_eq!(state.claim("gamma"), "F3");
    }

    #[test]
    fn store_remembers_across_opens() {
        let url = std::env::temp_dir().join(format!(
            "debrief-voices-{}.json",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let _cleanup = CleanupOnDrop(url.clone());

        let first = SessionVoiceStore::new(url.clone());
        assert_eq!(first.claim("alpha").unwrap(), "F1");
        let second = SessionVoiceStore::new(url.clone());
        assert_eq!(second.claim("beta").unwrap(), "F2");
        assert_eq!(second.claim("alpha").unwrap(), "F1");
    }

    struct CleanupOnDrop(std::path::PathBuf);
    impl Drop for CleanupOnDrop {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
}
