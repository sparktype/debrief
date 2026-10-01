// 발화 레인: 턴 브리핑(companion) vs 사실 보고(work)
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SpeechLane {
    Companion,
    Work,
}
