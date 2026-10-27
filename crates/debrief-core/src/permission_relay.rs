// Claude Code 채널 권한 중계 — MCP 프로세스가 받은 승인 요청과 CLI(`debrief allow|deny`) 판정을 파일로 주고받는다
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 답하지 않은 요청은 이 시간(초)이 지나면 버린다. 터미널에서 먼저 답해도 호스트는 알려 주지 않는다.
const EXPIRY_SECONDS: u64 = 10 * 60;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingPermission {
    pub request_id: String,
    pub tool_name: String,
    pub description: String,
    pub input_preview: String,
    /// 이 요청을 받은 `debrief mcp` 프로세스. 판정은 그 프로세스만 호스트에 돌려준다.
    pub owner_pid: u32,
    pub created: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum PermissionRelayError {
    InvalidRequestId,
    NotPending,
    /// id 없이 골랐는데 대기 요청이 여럿이다.
    Ambiguous(Vec<PendingPermission>),
    Io,
}

pub struct PermissionRelay {
    directory: PathBuf,
}

impl PermissionRelay {
    pub fn new(directory: PathBuf) -> Self {
        PermissionRelay { directory }
    }

    /// Claude Code의 요청 id는 `l`을 뺀 소문자 다섯 글자다. 파일 이름으로 쓰므로 그 밖은 받지 않는다.
    pub fn is_valid_request_id(id: &str) -> bool {
        id.len() == 5 && id.bytes().all(|b| b.is_ascii_lowercase() && b != b'l')
    }

    /// `notifications/claude/channel/permission_request`의 params를 대기 요청으로 남긴다.
    pub fn record(&self, params: &serde_json::Value, owner_pid: u32, now: u64) -> Result<(), PermissionRelayError> {
        let field = |key: &str| params.get(key).and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let pending = PendingPermission {
            request_id: field("request_id"),
            tool_name: field("tool_name"),
            description: field("description"),
            input_preview: field("input_preview"),
            owner_pid,
            created: now,
        };
        if !Self::is_valid_request_id(&pending.request_id) {
            return Err(PermissionRelayError::InvalidRequestId);
        }
        let data = serde_json::to_vec(&pending).expect("pending permission always serializes");
        self.write_private(&format!("{}.json", pending.request_id), &data)
    }

    /// 아직 답하지 않은 요청을 오래된 순으로 돌려주고, 만료된 요청은 지운다.
    pub fn pending(&self, now: u64) -> Vec<PendingPermission> {
        let Ok(entries) = std::fs::read_dir(&self.directory) else { return Vec::new() };
        let mut pending: Vec<PendingPermission> = entries
            .flatten()
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
            .filter_map(|entry| serde_json::from_slice(&std::fs::read(entry.path()).ok()?).ok())
            .filter(|request: &PendingPermission| {
                let expired = now.saturating_sub(request.created) > EXPIRY_SECONDS;
                if expired {
                    self.forget(&request.request_id);
                }
                !expired
            })
            .collect();
        pending.sort_by_key(|request| request.created);
        pending
    }

    /// CLI가 판정할 요청을 고른다. id를 주면 그 요청, 안 주면 대기 요청이 하나일 때만 그것.
    /// 두 번째 값은 id 없이 골랐는지(이때 CLI가 내용을 보여 주고 한 번 더 묻는다)다.
    pub fn target(&self, request_id: Option<&str>, now: u64) -> Result<(PendingPermission, bool), PermissionRelayError> {
        let mut pending = self.pending(now);
        match request_id {
            Some(id) if !Self::is_valid_request_id(id) => Err(PermissionRelayError::InvalidRequestId),
            Some(id) => pending
                .into_iter()
                .find(|request| request.request_id == id)
                .map(|request| (request, false))
                .ok_or(PermissionRelayError::NotPending),
            None if pending.len() > 1 => Err(PermissionRelayError::Ambiguous(pending)),
            None => pending.pop().map(|request| (request, true)).ok_or(PermissionRelayError::NotPending),
        }
    }

    /// 사람의 판정을 남긴다. 대기 중인 요청이어야 한다.
    pub fn decide(&self, request_id: &str, allow: bool, now: u64) -> Result<PendingPermission, PermissionRelayError> {
        if !Self::is_valid_request_id(request_id) {
            return Err(PermissionRelayError::InvalidRequestId);
        }
        let request = self
            .pending(now)
            .into_iter()
            .find(|request| request.request_id == request_id)
            .ok_or(PermissionRelayError::NotPending)?;
        self.write_private(&format!("{request_id}.verdict"), if allow { b"allow" } else { b"deny" })?;
        Ok(request)
    }

    /// 이 프로세스가 받은 요청 중 판정이 난 것을 (id, "allow"|"deny")로 꺼내고 파일을 지운다.
    pub fn take_verdicts(&self, owner_pid: u32, now: u64) -> Vec<(String, &'static str)> {
        self.pending(now)
            .into_iter()
            .filter(|request| request.owner_pid == owner_pid)
            .filter_map(|request| {
                let verdict = std::fs::read(self.directory.join(format!("{}.verdict", request.request_id))).ok()?;
                self.forget(&request.request_id);
                Some((request.request_id, if verdict == b"allow" { "allow" } else { "deny" }))
            })
            .collect()
    }

    /// 호스트에 돌려줄 판정 알림.
    pub fn verdict_notification(request_id: &str, behavior: &str) -> serde_json::Value {
        serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel/permission",
            "params": {"request_id": request_id, "behavior": behavior},
        })
    }

    fn forget(&self, request_id: &str) {
        let _ = std::fs::remove_file(self.directory.join(format!("{request_id}.json")));
        let _ = std::fs::remove_file(self.directory.join(format!("{request_id}.verdict")));
    }

    /// 승인 경로이므로 디렉터리 0700, 파일 0600으로 쓴다.
    fn write_private(&self, name: &str, data: &[u8]) -> Result<(), PermissionRelayError> {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        std::fs::create_dir_all(&self.directory).map_err(|_| PermissionRelayError::Io)?;
        std::fs::set_permissions(&self.directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| PermissionRelayError::Io)?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(self.directory.join(name))
            .map_err(|_| PermissionRelayError::Io)?;
        file.write_all(data).map_err(|_| PermissionRelayError::Io)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn relay(tag: &str) -> (PermissionRelay, PathBuf) {
        let directory = std::env::temp_dir().join(format!("debrief-relay-{}-{tag}", std::process::id()));
        std::fs::remove_dir_all(&directory).ok();
        (PermissionRelay::new(directory.clone()), directory)
    }

    fn request(id: &str) -> serde_json::Value {
        json!({"request_id": id, "tool_name": "Bash", "description": "Run tests", "input_preview": "{\"command\":\"cargo test\"}"})
    }

    #[test]
    fn request_ids_are_five_letters_without_l() {
        assert!(PermissionRelay::is_valid_request_id("abcde"));
        assert!(!PermissionRelay::is_valid_request_id("abcdl"));
        assert!(!PermissionRelay::is_valid_request_id("ABCDE"));
        assert!(!PermissionRelay::is_valid_request_id("../ab"));
        assert!(!PermissionRelay::is_valid_request_id("abcdef"));
    }

    #[test]
    fn verdict_reaches_only_the_owning_process_once() {
        let (relay, directory) = relay("owner");
        relay.record(&request("abcde"), 10, 100).unwrap();
        relay.record(&request("fghij"), 20, 101).unwrap();
        assert!(relay.record(&request("../x"), 10, 100).is_err());

        let pending = relay.pending(110);
        assert_eq!(pending.iter().map(|p| p.request_id.as_str()).collect::<Vec<_>>(), ["abcde", "fghij"]);
        assert_eq!(pending[0].input_preview, "{\"command\":\"cargo test\"}");

        assert_eq!(relay.decide("abcde", true, 120).unwrap().tool_name, "Bash");
        assert_eq!(relay.decide("zzzzz", true, 120), Err(PermissionRelayError::NotPending));
        assert!(relay.take_verdicts(20, 125).is_empty(), "다른 프로세스의 요청");
        assert_eq!(relay.take_verdicts(10, 125), vec![("abcde".to_string(), "allow")]);
        assert!(relay.take_verdicts(10, 126).is_empty(), "한 번만");
        relay.decide("fghij", false, 130).unwrap();
        assert_eq!(relay.take_verdicts(20, 131), vec![("fghij".to_string(), "deny")]);
        assert!(relay.pending(132).is_empty());

        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn target_needs_an_id_only_when_several_requests_wait() {
        let (relay, directory) = relay("target");
        assert_eq!(relay.target(None, 0), Err(PermissionRelayError::NotPending));
        relay.record(&request("abcde"), 10, 0).unwrap();
        assert_eq!(relay.target(None, 1).unwrap(), (relay.pending(1)[0].clone(), true));
        relay.record(&request("fghij"), 10, 1).unwrap();
        assert!(matches!(relay.target(None, 2), Err(PermissionRelayError::Ambiguous(list)) if list.len() == 2));
        assert_eq!(relay.target(Some("fghij"), 2).unwrap().0.request_id, "fghij");
        assert!(!relay.target(Some("fghij"), 2).unwrap().1);
        assert_eq!(relay.target(Some("x"), 2), Err(PermissionRelayError::InvalidRequestId));
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn stale_requests_expire() {
        let (relay, directory) = relay("expire");
        relay.record(&request("abcde"), 10, 0).unwrap();
        assert_eq!(relay.pending(EXPIRY_SECONDS).len(), 1);
        assert!(relay.pending(EXPIRY_SECONDS + 1).is_empty());
        assert_eq!(relay.decide("abcde", true, EXPIRY_SECONDS + 2), Err(PermissionRelayError::NotPending));
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn verdict_notification_matches_the_channel_contract() {
        let value = PermissionRelay::verdict_notification("abcde", "deny");
        assert_eq!(value["method"], "notifications/claude/channel/permission");
        assert_eq!(value["params"]["request_id"], "abcde");
        assert_eq!(value["params"]["behavior"], "deny");
        assert!(value.get("id").is_none(), "알림은 id가 없다");
    }
}
