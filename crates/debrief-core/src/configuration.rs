// debrief 모드·음소거·도우미 설정 구조체 및 CLI 명령 적용 로직
use crate::paths::DebriefPaths;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DebriefMode {
    Normal,
    Focus,
    Quiet,
    Verbose,
    Night,
}

impl DebriefMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            DebriefMode::Normal => "normal",
            DebriefMode::Focus => "focus",
            DebriefMode::Quiet => "quiet",
            DebriefMode::Verbose => "verbose",
            DebriefMode::Night => "night",
        }
    }

    pub fn from_str_value(value: &str) -> Option<Self> {
        match value {
            "normal" => Some(DebriefMode::Normal),
            "focus" => Some(DebriefMode::Focus),
            "quiet" => Some(DebriefMode::Quiet),
            "verbose" => Some(DebriefMode::Verbose),
            "night" => Some(DebriefMode::Night),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebriefConfiguration {
    #[serde(default = "default_mode")]
    pub mode: DebriefMode,
    #[serde(default)]
    pub muted: bool,
    #[serde(default = "default_companion_enabled")]
    pub companion_enabled: bool,
    #[serde(default = "DebriefConfiguration::default_volume_ceilings")]
    pub volume_ceilings: HashMap<String, f64>,
    #[serde(default)]
    pub category_voices: HashMap<String, String>,
    #[serde(default)]
    pub voice_speeds: HashMap<String, f64>,
    #[serde(default = "default_decide_enabled")]
    pub decide_enabled: bool,
    /// 에이전트가 말하지 않은 턴이 이 시간(초) 이상 걸렸으면 Stop 훅이 알린다. 0이면 끈다.
    #[serde(default = "default_long_turn_seconds")]
    pub long_turn_seconds: u64,
    /// 다른 프로젝트 세션이 동시에 활성이면 발화 앞에 프로젝트 이름을 붙인다.
    #[serde(default = "default_session_label")]
    pub session_label: bool,
    /// macOS 방해금지(집중 모드)가 켜져 있는 동안 유효 모드를 최소 quiet로 올린다. 기본 꺼짐.
    #[serde(default)]
    pub dnd_sync: bool,
    /// 에이전트 팀의 TeammateIdle·TaskCompleted 알림. 잦을 수 있어 기본 꺼짐.
    #[serde(default)]
    pub team_notices: bool,
}

fn default_mode() -> DebriefMode {
    DebriefMode::Normal
}

fn default_companion_enabled() -> bool {
    true
}

fn default_decide_enabled() -> bool {
    true
}

fn default_long_turn_seconds() -> u64 {
    60
}

fn default_session_label() -> bool {
    true
}

impl Default for DebriefConfiguration {
    fn default() -> Self {
        DebriefConfiguration {
            mode: DebriefMode::Normal,
            muted: false,
            companion_enabled: true,
            volume_ceilings: DebriefConfiguration::default_volume_ceilings(),
            category_voices: HashMap::new(),
            voice_speeds: HashMap::new(),
            decide_enabled: default_decide_enabled(),
            long_turn_seconds: default_long_turn_seconds(),
            session_label: default_session_label(),
            dnd_sync: false,
            team_notices: false,
        }
    }
}

impl DebriefConfiguration {
    pub fn default_volume_ceilings() -> HashMap<String, f64> {
        let mut ceilings = HashMap::new();
        ceilings.insert("normal".to_string(), 1.0);
        ceilings.insert("focus".to_string(), 1.0);
        ceilings.insert("quiet".to_string(), 0.45);
        ceilings.insert("verbose".to_string(), 1.0);
        ceilings.insert("night".to_string(), 0.20);
        ceilings
    }

    /// 방해금지 연동이 켜져 있고 집중 모드가 활성이면 저장된 모드를 바꾸지 않은 채
    /// 유효 모드만 최소 quiet로 올린 사본을 돌려준다(night은 그대로).
    pub fn with_dnd(&self, dnd_active: bool) -> Self {
        let mut effective = self.clone();
        if self.dnd_sync && dnd_active && effective.mode != DebriefMode::Night {
            effective.mode = DebriefMode::Quiet;
        }
        effective
    }

    /// 데몬이 발화마다 쓰는 설정 — 저장된 설정에 방해금지 상태를 반영한다.
    pub fn load_effective(url: &Path, home: &Path) -> Self {
        let configuration = Self::load(url);
        if !configuration.dnd_sync {
            return configuration;
        }
        let active = crate::macos_dnd::MacosDnd::is_active(home).unwrap_or(false);
        configuration.with_dnd(active)
    }

    pub fn load(url: &Path) -> Self {
        std::fs::read(url)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, url: &Path) -> std::io::Result<()> {
        use std::os::unix::fs::PermissionsExt;

        let directory = url.parent().expect("config url must have a parent directory");
        std::fs::create_dir_all(directory)?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;

        let data = serde_json::to_vec_pretty(self).expect("configuration always serializes");
        let temporary = directory.join(format!(
            ".{}.{}.tmp",
            url.file_name().unwrap().to_string_lossy(),
            std::process::id()
        ));

        // Write, fsync, and rename — clean up the temp file on any failure after creation.
        let result = (|| -> std::io::Result<()> {
            use std::io::Write;
            let mut file = std::fs::File::create(&temporary)?;
            file.write_all(&data)?;
            file.sync_all()?;
            drop(file);
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
            std::fs::rename(&temporary, url)?;
            Ok(())
        })();

        if result.is_err() {
            std::fs::remove_file(&temporary).ok();
        }
        result
    }
}

#[derive(Debug, PartialEq)]
pub enum ConfigurationCommandError {
    InvalidMode(String),
    InvalidMuteAction(String),
    InvalidCompanionAction(String),
    InvalidDndAction(String),
}

pub struct ConfigurationCommands;

impl ConfigurationCommands {
    pub fn apply_mode(raw_value: Option<&str>, home: &Path) -> Result<DebriefConfiguration, ConfigurationCommandError> {
        let url = DebriefPaths::for_home(home).config_url;
        let mut configuration = DebriefConfiguration::load(&url);
        let Some(raw_value) = raw_value else { return Ok(configuration) };
        let mode = DebriefMode::from_str_value(raw_value)
            .ok_or_else(|| ConfigurationCommandError::InvalidMode(raw_value.to_string()))?;
        configuration.mode = mode;
        configuration.save(&url).expect("save should succeed in this context");
        Ok(configuration)
    }

    pub fn apply_mute(raw_value: Option<&str>, home: &Path) -> Result<DebriefConfiguration, ConfigurationCommandError> {
        let url = DebriefPaths::for_home(home).config_url;
        let mut configuration = DebriefConfiguration::load(&url);
        match raw_value.unwrap_or("toggle") {
            "on" => configuration.muted = true,
            "off" => configuration.muted = false,
            "toggle" => configuration.muted = !configuration.muted,
            invalid => return Err(ConfigurationCommandError::InvalidMuteAction(invalid.to_string())),
        }
        configuration.save(&url).expect("save should succeed in this context");
        Ok(configuration)
    }

    pub fn apply_companion(raw_value: Option<&str>, home: &Path) -> Result<DebriefConfiguration, ConfigurationCommandError> {
        let url = DebriefPaths::for_home(home).config_url;
        let mut configuration = DebriefConfiguration::load(&url);
        match raw_value.unwrap_or("toggle") {
            "on" => configuration.companion_enabled = true,
            "off" => configuration.companion_enabled = false,
            "toggle" => configuration.companion_enabled = !configuration.companion_enabled,
            invalid => return Err(ConfigurationCommandError::InvalidCompanionAction(invalid.to_string())),
        }
        configuration.save(&url).expect("save should succeed in this context");
        Ok(configuration)
    }

    pub fn apply_dnd(raw_value: Option<&str>, home: &Path) -> Result<DebriefConfiguration, ConfigurationCommandError> {
        let url = DebriefPaths::for_home(home).config_url;
        let mut configuration = DebriefConfiguration::load(&url);
        match raw_value.unwrap_or("toggle") {
            "on" => configuration.dnd_sync = true,
            "off" => configuration.dnd_sync = false,
            "toggle" => configuration.dnd_sync = !configuration.dnd_sync,
            invalid => return Err(ConfigurationCommandError::InvalidDndAction(invalid.to_string())),
        }
        configuration.save(&url).expect("save should succeed in this context");
        Ok(configuration)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn temporary_directory() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("debrief-config-tests-{}", uuid_like()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn uuid_like() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::{SystemTime, UNIX_EPOCH};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("{nanos}-{counter}")
    }

    fn permissions(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn missing_and_corrupt_files_recover_to_defaults() {
        let directory = temporary_directory();
        let url = directory.join("config.json");

        assert_eq!(DebriefConfiguration::load(&url), DebriefConfiguration::default());
        fs::write(&url, "not-json").unwrap();
        assert_eq!(DebriefConfiguration::load(&url), DebriefConfiguration::default());

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn decide_enabled_defaults_to_true() {
        let configuration = DebriefConfiguration::default();
        assert!(configuration.decide_enabled);
    }

    #[test]
    fn decide_fields_missing_from_disk_load_as_defaults() {
        let directory = temporary_directory();
        let url = directory.join("config.json");
        fs::write(&url, "{}").unwrap();

        let loaded = DebriefConfiguration::load(&url);
        assert!(loaded.decide_enabled);

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn decide_fields_round_trip_through_save_and_load() {
        let directory = temporary_directory();
        let url = directory.join("config.json");

        let configuration = DebriefConfiguration {
            decide_enabled: false,
            ..Default::default()
        };
        configuration.save(&url).unwrap();

        let loaded = DebriefConfiguration::load(&url);
        assert!(!loaded.decide_enabled);

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn save_atomically_replaces_configuration_with_user_only_permissions() {
        let directory = temporary_directory();
        let url = directory.join("nested/config.json");

        let first = DebriefConfiguration { mode: DebriefMode::Normal, muted: false, ..Default::default() };
        first.save(&url).unwrap();

        let second = DebriefConfiguration { mode: DebriefMode::Night, muted: true, ..Default::default() };
        second.save(&url).unwrap();

        assert_eq!(DebriefConfiguration::load(&url).mode, DebriefMode::Night);
        assert!(DebriefConfiguration::load(&url).muted);
        assert_eq!(permissions(&url), 0o600);
        assert_eq!(permissions(url.parent().unwrap()), 0o700);
        let siblings: Vec<_> = fs::read_dir(url.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(siblings, vec![std::ffi::OsString::from("config.json")]);

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn loads_swift_shaped_config_json_with_camel_case_keys() {
        let directory = temporary_directory();
        let url = directory.join("config.json");
        let swift_shaped_json = r#"{
            "mode": "focus",
            "muted": true,
            "companionEnabled": false,
            "volumeCeilings": {"normal": 1.0},
            "categoryVoices": {"work": "F3"},
            "voiceSpeeds": {"F3": 1.1}
        }"#;
        fs::write(&url, swift_shaped_json).unwrap();

        let loaded = DebriefConfiguration::load(&url);

        assert_eq!(loaded.mode, DebriefMode::Focus);
        assert!(loaded.muted);
        assert!(!loaded.companion_enabled);
        assert_eq!(loaded.category_voices.get("work"), Some(&"F3".to_string()));
        assert_eq!(loaded.voice_speeds.get("F3"), Some(&1.1));

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn notice_settings_default_and_parse() {
        let defaults: DebriefConfiguration = serde_json::from_str("{}").unwrap();
        assert_eq!(defaults.long_turn_seconds, 60);
        assert!(defaults.session_label);
        assert!(!defaults.team_notices);

        let custom: DebriefConfiguration =
            serde_json::from_str(r#"{"longTurnSeconds": 0, "sessionLabel": false}"#).unwrap();
        assert_eq!(custom.long_turn_seconds, 0);
        assert!(!custom.session_label);
    }

    #[test]
    fn dnd_sync_defaults_off_and_raises_mode_to_quiet_only_when_active() {
        let default = DebriefConfiguration::default();
        assert!(!default.dnd_sync);
        assert_eq!(default.with_dnd(true).mode, DebriefMode::Normal, "옵트인 전에는 바꾸지 않는다");

        let synced = DebriefConfiguration { dnd_sync: true, ..DebriefConfiguration::default() };
        assert_eq!(synced.with_dnd(false).mode, DebriefMode::Normal);
        for (mode, expected) in [
            (DebriefMode::Normal, DebriefMode::Quiet),
            (DebriefMode::Verbose, DebriefMode::Quiet),
            (DebriefMode::Focus, DebriefMode::Quiet),
            (DebriefMode::Quiet, DebriefMode::Quiet),
            (DebriefMode::Night, DebriefMode::Night),
        ] {
            let configuration = DebriefConfiguration { mode, dnd_sync: true, ..DebriefConfiguration::default() };
            assert_eq!(configuration.with_dnd(true).mode, expected, "{mode:?}");
        }
    }

    #[test]
    fn apply_dnd_toggles_and_rejects_unknown_actions() {
        let directory = temporary_directory();
        let home = directory.as_path();
        assert!(ConfigurationCommands::apply_dnd(Some("on"), home).unwrap().dnd_sync);
        assert!(!ConfigurationCommands::apply_dnd(Some("toggle"), home).unwrap().dnd_sync);
        assert!(ConfigurationCommands::apply_dnd(None, home).unwrap().dnd_sync, "인자 없으면 toggle");
        assert_eq!(
            ConfigurationCommands::apply_dnd(Some("maybe"), home),
            Err(ConfigurationCommandError::InvalidDndAction("maybe".to_string()))
        );
        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn load_effective_reads_dnd_state_from_home_and_fails_open() {
        let home = temporary_directory();
        let paths = DebriefPaths::for_home(&home);
        DebriefConfiguration { dnd_sync: true, ..DebriefConfiguration::default() }.save(&paths.config_url).unwrap();

        // 방해금지 파일을 읽을 수 없으면 저장된 모드를 그대로 쓴다(fail-open).
        assert_eq!(DebriefConfiguration::load_effective(&paths.config_url, &home).mode, DebriefMode::Normal);

        let assertions = crate::macos_dnd::MacosDnd::assertions_url(&home);
        fs::create_dir_all(assertions.parent().unwrap()).unwrap();
        fs::write(&assertions, r#"{"data":[{"storeAssertionRecords":[{}]}]}"#).unwrap();
        assert_eq!(DebriefConfiguration::load_effective(&paths.config_url, &home).mode, DebriefMode::Quiet);

        // 저장된 설정 자체는 바뀌지 않는다.
        assert_eq!(DebriefConfiguration::load(&paths.config_url).mode, DebriefMode::Normal);
        fs::remove_dir_all(&home).ok();
    }
}
