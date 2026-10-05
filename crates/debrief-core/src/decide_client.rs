// 로컬 decide 데몬(UDS) 판단 모델 연동 — 불가하면 항상 None(폴백)
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// decide 데몬은 요청의 client_version이 자기 버전과 다르면 stale로 답하고 끝난다.
/// 그 경우 응답에 answers가 없어 None으로 폴백한다. decide를 올리면 이 값도 맞춘다.
const DECIDE_CLIENT_VERSION: &str = "0.5.0";

pub trait DecideJudge: Send + Sync {
    fn noul(&self, state: &str, instructions: &str) -> Option<f64>;
    fn choice(&self, state: &str, instructions: &str, options: &[&str]) -> Option<String>;
}

pub struct SocketDecideClient {
    socket: PathBuf,
    timeout: Duration,
}

impl SocketDecideClient {
    pub fn new(socket: PathBuf) -> Self {
        SocketDecideClient { socket, timeout: Duration::from_millis(1200) }
    }

    fn request(&self, question: serde_json::Value, state: &str) -> Option<serde_json::Value> {
        let body = serde_json::json!({
            "client_version": DECIDE_CLIENT_VERSION,
            "state": state,
            "questions": { "q": question },
        });
        let mut stream = UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(self.timeout)).ok()?;
        stream.set_write_timeout(Some(self.timeout)).ok()?;
        writeln!(stream, "{body}").ok()?;
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).ok()?;
        serde_json::from_str(&line).ok()
    }
}

impl DecideJudge for SocketDecideClient {
    fn noul(&self, state: &str, instructions: &str) -> Option<f64> {
        let response = self.request(serde_json::json!({ "type": "noul", "instructions": instructions }), state)?;
        response.get("answers")?.get("q")?.get("noul")?.as_f64()
    }

    fn choice(&self, state: &str, instructions: &str, options: &[&str]) -> Option<String> {
        let question = serde_json::json!({ "type": "choice", "instructions": instructions, "options": options });
        let response = self.request(question, state)?;
        response.get("answers")?.get("q")?.get("choice")?.as_str().map(|s| s.to_string())
    }
}

pub struct NoopDecideClient;

impl DecideJudge for NoopDecideClient {
    fn noul(&self, _state: &str, _instructions: &str) -> Option<f64> {
        None
    }

    fn choice(&self, _state: &str, _instructions: &str, _options: &[&str]) -> Option<String> {
        None
    }
}

#[cfg(test)]
pub struct FakeDecideClient {
    pub noul_response: Option<f64>,
    pub choice_response: Option<String>,
}

#[cfg(test)]
impl DecideJudge for FakeDecideClient {
    fn noul(&self, _state: &str, _instructions: &str) -> Option<f64> {
        self.noul_response
    }

    fn choice(&self, _state: &str, _instructions: &str, _options: &[&str]) -> Option<String> {
        self.choice_response.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noop_client_always_falls_back_to_none() {
        let client = NoopDecideClient;
        assert_eq!(client.noul("state", "instructions"), None);
        assert_eq!(client.choice("state", "instructions", &["a", "b"]), None);
    }

    #[test]
    fn fake_client_returns_canned_responses() {
        let client = FakeDecideClient { noul_response: Some(0.75), choice_response: Some("warm".to_string()) };
        assert_eq!(client.noul("x", "y"), Some(0.75));
        assert_eq!(client.choice("x", "y", &["warm", "neutral"]), Some("warm".to_string()));
    }

    #[test]
    fn socket_client_missing_socket_falls_back_to_none() {
        let client = SocketDecideClient::new(PathBuf::from("/tmp/debrief-decide-missing.sock"));
        assert_eq!(client.noul("state", "instructions"), None);
        assert_eq!(client.choice("state", "instructions", &["a", "b"]), None);
    }

    /// 한 줄 요청을 받아 reply를 돌려주는 가짜 decide 데몬. 받은 요청을 반환한다.
    fn serve_once(name: &str, reply: &'static str) -> (PathBuf, std::thread::JoinHandle<serde_json::Value>) {
        let path = std::env::temp_dir().join(format!("dd-{}-{name}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            writeln!(&stream, "{reply}").unwrap();
            serde_json::from_str(&line).unwrap()
        });
        (path, handle)
    }

    #[test]
    fn socket_client_sends_versioned_request_and_parses_noul() {
        let (path, server) = serve_once("noul", r#"{"answers":{"q":{"type":"noul","noul":0.75}}}"#);
        let client = SocketDecideClient::new(path.clone());
        assert_eq!(client.noul("상태", "질문?"), Some(0.75));
        let request = server.join().unwrap();
        assert_eq!(request["client_version"], DECIDE_CLIENT_VERSION);
        assert_eq!(request["state"], "상태");
        assert_eq!(request["questions"]["q"]["type"], "noul");
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn socket_client_parses_choice_and_sends_options() {
        let (path, server) = serve_once("choice", r#"{"answers":{"q":{"type":"choice","choice":"warm"}}}"#);
        let client = SocketDecideClient::new(path.clone());
        assert_eq!(client.choice("s", "i", &["warm", "neutral"]), Some("warm".to_string()));
        let request = server.join().unwrap();
        assert_eq!(request["questions"]["q"]["options"], serde_json::json!(["warm", "neutral"]));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn socket_client_stale_reply_falls_back_to_none() {
        let (path, server) = serve_once("stale", r#"{"error":"stale"}"#);
        let client = SocketDecideClient::new(path.clone());
        assert_eq!(client.noul("s", "i"), None);
        server.join().unwrap();
        std::fs::remove_file(path).ok();
    }
}
