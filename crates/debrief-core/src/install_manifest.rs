// 설치가 소유한 훅·파일·런타임 파일을 추적하는 매니페스트 — repair/uninstall 시 참조
use crate::hook_event::{HookEventName, HostSource};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OwnedHook {
    pub host: HostSource,
    pub event: HookEventName,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OwnedInstalledFile {
    pub host: HostSource,
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OwnedRuntimeFile {
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct InstallManifest {
    #[serde(default)]
    pub hooks: Vec<OwnedHook>,
    #[serde(default)]
    pub files: Vec<OwnedInstalledFile>,
    #[serde(default)]
    pub runtime_files: Vec<OwnedRuntimeFile>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum InstallManifestError {
    Io,
}

impl InstallManifest {
    pub fn load(url: &Path) -> Result<InstallManifest, InstallManifestError> {
        if !url.exists() {
            return Ok(InstallManifest::default());
        }
        let data = fs::read(url).map_err(|_| InstallManifestError::Io)?;
        serde_json::from_slice(&data).map_err(|_| InstallManifestError::Io)
    }

    pub fn save(&self, url: &Path) -> Result<(), InstallManifestError> {
        let data = serde_json::to_vec_pretty(self).map_err(|_| InstallManifestError::Io)?;
        AtomicInstallerFile::write(&data, url, 0o600).map_err(|_| InstallManifestError::Io)
    }
}

pub struct InstallerDigest;

impl InstallerDigest {
    pub fn data(data: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(data);
        hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect()
    }

    pub fn json(value: &serde_json::Value) -> Result<String, serde_json::Error> {
        Ok(Self::data(&serde_json::to_vec(value)?))
    }
}

pub struct AtomicInstallerFile;

impl AtomicInstallerFile {
    pub fn write(data: &[u8], url: &Path, permissions: u32) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;

        let directory = url.parent().expect("install manifest url must have a parent directory");
        fs::create_dir_all(directory)?;
        let temporary = directory.join(format!(
            ".{}.{}.tmp",
            url.file_name().unwrap().to_string_lossy(),
            std::process::id()
        ));

        let result = (|| -> std::io::Result<()> {
            let mut file = fs::File::create(&temporary)?;
            file.write_all(data)?;
            file.sync_all()?;
            drop(file);
            fs::set_permissions(&temporary, fs::Permissions::from_mode(permissions))?;
            fs::rename(&temporary, url)?;
            Ok(())
        })();

        if result.is_err() {
            fs::remove_file(&temporary).ok();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temporary_directory() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "debrief-install-manifest-tests-{}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_manifest_loads_as_default() {
        let directory = temporary_directory();
        let url = directory.join("install-manifest.json");
        assert_eq!(InstallManifest::load(&url).unwrap(), InstallManifest::default());
        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn round_trips_through_save_and_load() {
        let directory = temporary_directory();
        let url = directory.join("install-manifest.json");
        let manifest = InstallManifest {
            hooks: vec![OwnedHook { host: HostSource::Claude, event: HookEventName::SessionStart, sha256: "a".repeat(64) }],
            files: vec![OwnedInstalledFile {
                host: HostSource::Codex,
                path: ".codex/hooks.json".to_string(),
                sha256: "b".repeat(64),
            }],
            runtime_files: vec![OwnedRuntimeFile { path: "bin/debrief".to_string(), sha256: "c".repeat(64) }],
        };
        manifest.save(&url).unwrap();
        assert_eq!(InstallManifest::load(&url).unwrap(), manifest);
        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn save_sets_user_only_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let directory = temporary_directory();
        let url = directory.join("install-manifest.json");
        InstallManifest::default().save(&url).unwrap();
        let mode = fs::metadata(&url).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn digest_is_deterministic_sha256_hex() {
        let value = serde_json::json!({"a": 2, "b": 1});
        let digest = InstallerDigest::json(&value).unwrap();
        assert_eq!(digest.len(), 64);
        assert_eq!(digest, InstallerDigest::json(&value).unwrap());
    }
}
