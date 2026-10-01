// debrief 버전 문자열 — Cargo.toml의 패키지 버전과 함께 유지한다
pub struct DebriefVersion;

impl DebriefVersion {
    pub const CURRENT: &'static str = env!("CARGO_PKG_VERSION");
}
