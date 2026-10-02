// 로컬 decide(jev-style serve) 판단 모델 연동 — 불가하면 항상 None(폴백)
use std::time::Duration;

pub trait DecideJudge: Send + Sync {
    fn noul(&self, state: &str, instructions: &str) -> Option<f64>;
    fn choice(&self, state: &str, instructions: &str, options: &[&str]) -> Option<String>;
}

pub struct HttpDecideClient {
    endpoint: String,
    timeout: Duration,
}

impl HttpDecideClient {
    pub fn new(endpoint: String) -> Self {
        HttpDecideClient { endpoint, timeout: Duration::from_millis(1200) }
    }

    fn agent(&self) -> ureq::Agent {
        let config = ureq::Agent::config_builder().timeout_global(Some(self.timeout)).build();
        ureq::Agent::new_with_config(config)
    }

    fn post(&self, body: &serde_json::Value) -> Option<serde_json::Value> {
        let agent = self.agent();
        let url = format!("{}/v1/systemone", self.endpoint);
        let attempt = |agent: &ureq::Agent| -> Result<serde_json::Value, ureq::Error> {
            let mut response = agent.post(&url).send_json(body)?;
            let text = response.body_mut().read_to_string()?;
            serde_json::from_str(&text).map_err(|_| ureq::Error::BadUri(url.clone()))
        };

        match attempt(&agent) {
            Ok(value) => Some(value),
            Err(ureq::Error::Io(ref io_error)) if io_error.kind() == std::io::ErrorKind::ConnectionReset => {
                attempt(&agent).ok()
            }
            Err(_) => None,
        }
    }
}

impl DecideJudge for HttpDecideClient {
    fn noul(&self, state: &str, instructions: &str) -> Option<f64> {
        let body = serde_json::json!({
            "state": state,
            "questions": { "q": { "type": "noul", "instructions": instructions } },
        });
        let response = self.post(&body)?;
        response.get("answers")?.get("q")?.get("noul")?.as_f64()
    }

    fn choice(&self, state: &str, instructions: &str, options: &[&str]) -> Option<String> {
        let criteria: serde_json::Map<String, serde_json::Value> =
            options.iter().map(|option| (option.to_string(), serde_json::Value::Null)).collect();
        let body = serde_json::json!({
            "state": state,
            "questions": {
                "q": { "type": "choice", "instructions": instructions, "criteria": criteria },
            },
        });
        let response = self.post(&body)?;
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
    fn http_client_unreachable_endpoint_falls_back_to_none() {
        let client = HttpDecideClient::new("http://127.0.0.1:1".to_string());
        assert_eq!(client.noul("state", "instructions"), None);
        assert_eq!(client.choice("state", "instructions", &["a", "b"]), None);
    }
}
