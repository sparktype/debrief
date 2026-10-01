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
}

fn default_mode() -> DebriefMode {
    DebriefMode::Normal
}

fn default_companion_enabled() -> bool {
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
}
