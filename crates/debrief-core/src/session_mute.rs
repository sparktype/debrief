// 세션별 음소거 — CLI가 남긴 대기 요청을 다음 UserPromptSubmit 훅이 그 세션에 적용하는 저장소
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 대기 요청이 유효한 시간(초).
const PENDING_TTL_SECONDS: u64 = 5 * 60;
/// 음소거 세션 집합의 상한. 넘으면 오래된 것부터 버린다.
const MUTED_LIMIT: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PendingMute {
    /// `true`면 음소거, `false`면 해제 요청.
    pub mute: bool,
    pub at: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionMutes {
    /// 오래된 순.
    #[serde(default)]
    pub muted: Vec<String>,
    #[serde(default)]
    pub pending: Option<PendingMute>,
}

impl SessionMutes {
    /// 새 요청은 반대 요청을 덮어쓴다(대기는 하나뿐).
    pub fn request(&mut self, mute: bool, now: u64) {
        self.pending = Some(PendingMute { mute, at: now });
    }

    /// 유효한 대기 요청이 있으면 이 세션에 적용하고 (음소거 여부)를 돌려준다. 만료된 요청은 버린다.
    pub fn consume(&mut self, session_id: &str, now: u64) -> Option<bool> {
        let pending = self.pending.take()?;
        if now.saturating_sub(pending.at) > PENDING_TTL_SECONDS {
            return None;
        }
        self.muted.retain(|id| id != session_id);
        if pending.mute {
            self.muted.push(session_id.to_string());
            let overflow = self.muted.len().saturating_sub(MUTED_LIMIT);
            self.muted.drain(..overflow);
        }
        Some(pending.mute)
    }

    pub fn is_muted(&self, session_id: &str) -> bool {
        self.muted.iter().any(|id| id == session_id)
    }
}

pub struct SessionMuteStore {
    url: PathBuf,
}

impl SessionMuteStore {
    pub fn new(url: PathBuf) -> Self {
        SessionMuteStore { url }
    }

    pub fn load(&self) -> SessionMutes {
        std::fs::read(&self.url).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    // shortcut: 잠금 없는 읽고-쓰기라 두 훅이 동시에 소비하면 한쪽이 덮일 수 있다. 사람이 손으로 거는 드문 요청이라 감수한다.
    pub fn update<R>(&self, change: impl FnOnce(&mut SessionMutes) -> R) -> std::io::Result<R> {
        use std::os::unix::fs::PermissionsExt;
        let directory = self.url.parent().expect("session mute url must have a parent directory");
        std::fs::create_dir_all(directory)?;
        let mut state = self.load();
        let value = change(&mut state);
        let temporary = directory.join(format!(".session-mutes.{}.tmp", std::process::id()));
        let result = (|| {
            std::fs::write(&temporary, serde_json::to_vec(&state).expect("session mutes always serialize"))?;
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
            std::fs::rename(&temporary, &self.url)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result.map(|_| value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_replaces_the_opposite_pending() {
        let mut mutes = SessionMutes::default();
        mutes.request(true, 10);
        mutes.request(false, 20);
        assert_eq!(mutes.pending, Some(PendingMute { mute: false, at: 20 }));
    }

    #[test]
    fn consume_applies_mute_and_unmute_once() {
        let mut mutes = SessionMutes::default();
        mutes.request(true, 100);
        assert_eq!(mutes.consume("a", 110), Some(true));
        assert!(mutes.is_muted("a"));
        assert_eq!(mutes.consume("b", 111), None, "대기 요청은 한 번만 쓰인다");
        assert!(!mutes.is_muted("b"));

        mutes.request(false, 200);
        assert_eq!(mutes.consume("a", 201), Some(false));
        assert!(!mutes.is_muted("a"));
    }

    #[test]
    fn pending_expires_after_five_minutes() {
        let mut mutes = SessionMutes::default();
        mutes.request(true, 0);
        assert_eq!(mutes.consume("a", PENDING_TTL_SECONDS + 1), None);
        assert!(!mutes.is_muted("a"));
        assert_eq!(mutes.pending, None, "만료된 요청은 비워진다");

        mutes.request(true, 0);
        assert_eq!(mutes.consume("a", PENDING_TTL_SECONDS), Some(true), "경계는 유효");
    }

    #[test]
    fn muted_set_is_capped_dropping_oldest() {
        let mut mutes = SessionMutes::default();
        for index in 0..MUTED_LIMIT + 2 {
            mutes.request(true, 0);
            mutes.consume(&format!("s{index}"), 0);
        }
        assert_eq!(mutes.muted.len(), MUTED_LIMIT);
        assert!(!mutes.is_muted("s0") && !mutes.is_muted("s1"));
        assert!(mutes.is_muted(&format!("s{}", MUTED_LIMIT + 1)));
    }

    #[test]
    fn store_roundtrips() {
        let directory = std::env::temp_dir().join(format!("debrief-mutes-{}-{}", std::process::id(), line!()));
        let store = SessionMuteStore::new(directory.join("session-mutes.json"));
        store.update(|m| m.request(true, 5)).unwrap();
        assert_eq!(store.load().pending, Some(PendingMute { mute: true, at: 5 }));
        std::fs::remove_dir_all(directory).ok();
    }
}
