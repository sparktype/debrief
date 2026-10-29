// 설치가 끝난 뒤 스피커와 모델이 살아 있는지 한 문장으로 확인한다.
// 데몬이나 오디오가 없어도 설치 자체는 실패로 만들지 않고 doctor 오류만 남긴다.
use crate::diagnostics::Diagnostics;
use crate::earcon::Earcon;
use crate::paths::DebriefPaths;
use crate::speech_emotion::SpeechEmotion;
use crate::speech_envelope::SpeechEnvelope;
use crate::speech_lane::SpeechLane;
use crate::speech_request::{SpeechPriority, SpeechRequest};
use crate::unix_socket::UnixSocketClient;
use std::path::Path;
use std::thread;
use std::time::Duration;

pub struct InstallChime;

impl InstallChime {
    pub const TEXT: &'static str = "설치가 끝났습니다. 이제 에이전트가 말하면 들려 드립니다.";

    pub fn request() -> SpeechRequest {
        SpeechRequest {
            envelope: SpeechEnvelope {
                v: 1,
                text: Self::TEXT.to_string(),
                voice: "F1".to_string(),
                speed: 0.93,
                volume: 0.85,
            },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Work,
            emotion: SpeechEmotion::Neutral,
            agent_type: None,
            decision: false,
            cue: Some(Earcon::Done),
            replayed: false,
            session: None,
        }
    }

    /// 소켓이 곧 열릴 수 있어 짧게 몇 번만 시도한다. 실패해도 호출자는 설치 성공으로 끝낸다.
    pub fn try_play(home: &Path) {
        let socket = DebriefPaths::for_home(home).socket_url;
        let client = UnixSocketClient::new(socket);
        let request = Self::request();
        for attempt in 0..4 {
            if client.is_reachable() && client.submit(&request).is_ok() {
                return;
            }
            if attempt + 1 < 4 {
                thread::sleep(Duration::from_millis(40));
            }
        }
        let _ = Diagnostics::new(home).record_error(
            "install",
            "chime_unavailable",
            "설치는 끝났지만 확인 음성을 재생하지 못했습니다. 스피커와 debrief doctor를 확인해 주세요.",
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn home() -> PathBuf {
        let url = PathBuf::from("/tmp").join(format!(
            "chime-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&url).unwrap();
        url
    }

    #[test]
    fn chime_is_one_polite_sentence_on_the_work_lane() {
        let request = InstallChime::request();
        assert_eq!(request.envelope.text, "설치가 끝났습니다. 이제 에이전트가 말하면 들려 드립니다.");
        assert_eq!(request.lane, SpeechLane::Work);
        assert_eq!(request.cue, Some(Earcon::Done));
    }

    #[test]
    fn missing_daemon_records_a_doctor_error_and_does_not_panic() {
        let home = home();
        InstallChime::try_play(&home);
        let error = Diagnostics::new(&home).current_error().expect("doctor 기록");
        assert_eq!(error.code, "chime_unavailable");
        assert!(error.message.contains("확인해 주세요"));
        fs::remove_dir_all(&home).ok();
    }
}
