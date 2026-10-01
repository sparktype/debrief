// 모델 자산 다운로드, 검증, 원자적 설치
use crate::model_manifest::{ModelAsset, ModelManifest};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

pub trait ModelDownloading: Send + Sync {
    fn download(&self, asset: &ModelAsset, destination: &Path) -> Result<(), ModelInstallerError>;
}

pub struct UreqModelDownloader;

impl UreqModelDownloader {
    pub fn new() -> Self {
        UreqModelDownloader
    }
}

impl Default for UreqModelDownloader {
    fn default() -> Self {
        Self::new()
    }
}

impl ModelDownloading for UreqModelDownloader {
    fn download(&self, asset: &ModelAsset, destination: &Path) -> Result<(), ModelInstallerError> {
        use ureq::tls::{TlsConfig, TlsProvider};

        let tls_config = TlsConfig::builder().provider(TlsProvider::NativeTls).build();
        let config = ureq::Agent::config_builder().tls_config(tls_config).build();
        let agent = ureq::Agent::new_with_config(config);

        let mut response = agent.get(&asset.url).call().map_err(|_| ModelInstallerError::DownloadFailed)?;

        let mut file = std::fs::File::create(destination).map_err(|_| ModelInstallerError::DownloadFailed)?;
        std::io::copy(&mut response.body_mut().as_reader(), &mut file)
            .map_err(|_| ModelInstallerError::DownloadFailed)?;

        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(destination, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| ModelInstallerError::DownloadFailed)?;
        file.sync_all().map_err(|_| ModelInstallerError::DownloadFailed)?;
        Ok(())
    }
}

#[derive(Debug, PartialEq)]
pub enum ModelInstallerError {
    DownloadFailed,
    ByteCountMismatch,
    ChecksumMismatch,
    InvalidCurrentPointer,
    AtomicReplacementFailed,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstalledModel {
    pub revision: String,
    pub directory: PathBuf,
}

impl InstalledModel {
    pub fn resolve_current(models_directory: &Path, name: &str) -> Result<InstalledModel, ModelInstallerError> {
        let root = models_directory.join(name);
        let pointer_path = root.join("current.json");
        let data = fs::read(&pointer_path).map_err(|_| ModelInstallerError::InvalidCurrentPointer)?;
        let pointer: CurrentModelPointer =
            serde_json::from_slice(&data).map_err(|_| ModelInstallerError::InvalidCurrentPointer)?;
        let is_hex40 = pointer.revision.len() == 40 && pointer.revision.chars().all(|c| c.is_ascii_hexdigit());
        if !is_hex40 || pointer.relative_path != pointer.revision {
            return Err(ModelInstallerError::InvalidCurrentPointer);
        }
        let directory = root.join(&pointer.relative_path);
        if !directory.is_dir() {
            return Err(ModelInstallerError::InvalidCurrentPointer);
        }
        Ok(InstalledModel { revision: pointer.revision, directory })
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CurrentModelPointer {
    revision: String,
    relative_path: String,
}

pub struct ModelInstaller<D: ModelDownloading> {
    models_directory: PathBuf,
    manifest: ModelManifest,
    downloader: D,
}

impl<D: ModelDownloading> ModelInstaller<D> {
    const INSTALLATION_NAME: &'static str = "supertonic-3";

    pub fn new(models_directory: PathBuf, manifest: ModelManifest, downloader: D) -> Self {
        ModelInstaller { models_directory, manifest, downloader }
    }

    fn validate_asset(asset: &ModelAsset, path: &Path) -> Result<(), ModelInstallerError> {
        let metadata = fs::metadata(path).map_err(|_| ModelInstallerError::ChecksumMismatch)?;
        if metadata.len() != asset.byte_count {
            return Err(ModelInstallerError::ChecksumMismatch);
        }
        let data = fs::read(path).map_err(|_| ModelInstallerError::ChecksumMismatch)?;
        let mut hasher = Sha256::new();
        hasher.update(&data);
        let digest: String = hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect();
        if digest != asset.sha256 {
            return Err(ModelInstallerError::ChecksumMismatch);
        }
        Ok(())
    }

    fn is_asset_valid(asset: &ModelAsset, path: &Path) -> bool {
        Self::validate_asset(asset, path).is_ok()
    }

    pub fn install(&self, repair: bool) -> Result<InstalledModel, ModelInstallerError> {
        self.manifest.validate().map_err(|_| ModelInstallerError::InvalidCurrentPointer)?;
        let root = self.models_directory.join(Self::INSTALLATION_NAME);
        let final_dir = root.join(&self.manifest.revision);
        let staging = root.join(format!(".staging-{}", std::process::id()));
        fs::create_dir_all(&root).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        fs::create_dir_all(&staging).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;

        if let Err(e) = self.install_assets(&final_dir, &staging, repair) {
            let _ = fs::remove_dir_all(&staging);
            return Err(e);
        }

        if let Err(e) = self.write_validated_marker(&staging) {
            let _ = fs::remove_dir_all(&staging);
            return Err(e);
        }

        if let Err(e) = sync_directory(&staging) {
            let _ = fs::remove_dir_all(&staging);
            return Err(e);
        }

        if final_dir.exists() {
            // SAFETY: path_cstr produces valid null-terminated C strings from UTF-8 paths;
            // AT_FDCWD resolves relative to the process's current directory, which is not
            // used here since both `staging` and `final_dir` are absolute paths.
            let swapped = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    path_cstr(&staging).as_ptr(),
                    libc::AT_FDCWD,
                    path_cstr(&final_dir).as_ptr(),
                    libc::RENAME_SWAP,
                )
            };
            if swapped != 0 {
                let _ = fs::remove_dir_all(&staging);
                return Err(ModelInstallerError::AtomicReplacementFailed);
            }
            let _ = fs::remove_dir_all(&staging);
        } else {
            fs::rename(&staging, &final_dir).map_err(|_| {
                let _ = fs::remove_dir_all(&staging);
                ModelInstallerError::AtomicReplacementFailed
            })?;
        }

        sync_directory(&root)?;
        self.write_current_pointer(&root)?;
        Ok(InstalledModel { revision: self.manifest.revision.clone(), directory: final_dir })
    }

    fn install_assets(&self, final_dir: &Path, staging: &Path, repair: bool) -> Result<(), ModelInstallerError> {
        for asset in &self.manifest.assets {
            let destination = staging.join(&asset.relative_path);
            fs::create_dir_all(destination.parent().unwrap())
                .map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
            let existing = final_dir.join(&asset.relative_path);
            if repair && Self::is_asset_valid(asset, &existing) {
                fs::copy(&existing, &destination).map_err(|_| ModelInstallerError::DownloadFailed)?;
            } else {
                self.downloader.download(asset, &destination)?;
            }
            Self::validate_asset(asset, &destination)?;
        }
        Ok(())
    }

    fn write_validated_marker(&self, staging: &Path) -> Result<(), ModelInstallerError> {
        use std::io::Write;
        let marker = staging.join(".validated.json");
        let data = serde_json::to_vec(&self.manifest).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        let mut file = fs::File::create(&marker).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        file.write_all(&data).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        file.sync_all().map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        Ok(())
    }

    fn write_current_pointer(&self, root: &Path) -> Result<(), ModelInstallerError> {
        use std::io::Write;
        let pointer = CurrentModelPointer {
            revision: self.manifest.revision.clone(),
            relative_path: self.manifest.revision.clone(),
        };
        let data = serde_json::to_vec(&pointer).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        let temporary = root.join(format!(".current-{}.json", std::process::id()));
        let mut file = fs::File::create(&temporary).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        file.write_all(&data).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        file.sync_all().map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        drop(file);
        let current = root.join("current.json");
        if current.exists() {
            // SAFETY: path_cstr produces valid null-terminated C strings from UTF-8 paths;
            // AT_FDCWD resolves relative to the process's current directory, which is not
            // used here since both `temporary` and `current` are absolute paths.
            let swapped = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    path_cstr(&temporary).as_ptr(),
                    libc::AT_FDCWD,
                    path_cstr(&current).as_ptr(),
                    libc::RENAME_SWAP,
                )
            };
            if swapped != 0 {
                let _ = fs::remove_file(&temporary);
                return Err(ModelInstallerError::AtomicReplacementFailed);
            }
            let _ = fs::remove_file(&temporary);
        } else if fs::rename(&temporary, &current).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(ModelInstallerError::AtomicReplacementFailed);
        }
        sync_directory(root)
    }
}

fn path_cstr(path: &Path) -> std::ffi::CString {
    std::ffi::CString::new(path.as_os_str().to_str().unwrap()).unwrap()
}

fn sync_directory(path: &Path) -> Result<(), ModelInstallerError> {
    use std::os::unix::io::AsRawFd;
    let dir = std::fs::File::open(path).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
    // SAFETY: `dir` is a valid, open file descriptor for the lifetime of this call
    // (owned by `dir`, not yet dropped); fsync on a directory fd is a well-defined
    // way to flush directory-entry metadata to durable storage on macOS.
    let ret = unsafe { libc::fsync(dir.as_raw_fd()) };
    if ret != 0 {
        return Err(ModelInstallerError::AtomicReplacementFailed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct FakeModelDownloader {
        contents: HashMap<String, Vec<u8>>,
        requested_paths: Mutex<Vec<String>>,
    }

    impl FakeModelDownloader {
        fn new(contents: HashMap<String, Vec<u8>>) -> Self {
            FakeModelDownloader { contents, requested_paths: Mutex::new(Vec::new()) }
        }

        fn requested_paths(&self) -> Vec<String> {
            self.requested_paths.lock().unwrap().clone()
        }
    }

    impl ModelDownloading for FakeModelDownloader {
        fn download(&self, asset: &ModelAsset, destination: &Path) -> Result<(), ModelInstallerError> {
            self.requested_paths.lock().unwrap().push(asset.relative_path.clone());
            let data = self.contents.get(&asset.url).ok_or(ModelInstallerError::DownloadFailed)?;
            fs::write(destination, data).map_err(|_| ModelInstallerError::DownloadFailed)
        }
    }

    fn sha256_hex(data: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(data);
        hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect()
    }

    fn fixture_manifest(revision: &str, files: &[(&str, &[u8])]) -> ModelManifest {
        let assets = files
            .iter()
            .map(|(path, data)| ModelAsset {
                relative_path: path.to_string(),
                url: format!("https://example.invalid/resolve/{revision}/{path}"),
                byte_count: data.len() as u64,
                sha256: sha256_hex(data),
            })
            .collect();
        let manifest = ModelManifest {
            name: "fixture".to_string(),
            revision: revision.to_string(),
            assets,
        };
        manifest.validate().expect("fixture manifest must be valid");
        manifest
    }

    fn temporary_directory() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("debrief-model-installer-tests-{nanos}-{counter}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn repair_downloads_only_missing_or_invalid_files() {
        let root = temporary_directory();
        let first = b"already valid".to_vec();
        let second = b"download me".to_vec();
        let revision = "a".repeat(40);
        let manifest = fixture_manifest(&revision, &[("onnx/a.bin", &first), ("voice_styles/F1.json", &second)]);
        let revision_dir = root.join("supertonic-3").join(&manifest.revision);
        let existing = revision_dir.join("onnx/a.bin");
        fs::create_dir_all(existing.parent().unwrap()).unwrap();
        fs::write(&existing, &first).unwrap();

        let mut contents = HashMap::new();
        for asset in &manifest.assets {
            let data = if asset.relative_path.ends_with("a.bin") { &first } else { &second };
            contents.insert(asset.url.clone(), data.clone());
        }
        let downloader = FakeModelDownloader::new(contents);

        let installer = ModelInstaller::new(root.clone(), manifest, downloader);
        let installed = installer.install(true).unwrap();

        assert_eq!(installer.downloader.requested_paths(), vec!["voice_styles/F1.json".to_string()]);
        assert_eq!(fs::read(installed.directory.join("onnx/a.bin")).unwrap(), first);
        assert_eq!(fs::read(installed.directory.join("voice_styles/F1.json")).unwrap(), second);
        assert_eq!(InstalledModel::resolve_current(&root, "supertonic-3").unwrap(), installed);

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn checksum_failure_preserves_previously_active_revision() {
        let root = temporary_directory();
        let old_data = b"old-good".to_vec();
        let old_manifest = fixture_manifest(&"1".repeat(40), &[("onnx/model.bin", &old_data)]);
        let mut old_contents = HashMap::new();
        old_contents.insert(old_manifest.assets[0].url.clone(), old_data.clone());
        let old_installer = ModelInstaller::new(root.clone(), old_manifest, FakeModelDownloader::new(old_contents));
        let old_installed = old_installer.install(false).unwrap();
        let pointer_path = root.join("supertonic-3/current.json");
        let pointer_before = fs::read(&pointer_path).unwrap();

        let new_manifest = fixture_manifest(&"2".repeat(40), &[("onnx/model.bin", b"new-good")]);
        let mut corrupt_contents = HashMap::new();
        corrupt_contents.insert(new_manifest.assets[0].url.clone(), b"corrupt".to_vec());
        let new_installer = ModelInstaller::new(root.clone(), new_manifest.clone(), FakeModelDownloader::new(corrupt_contents));

        let result = new_installer.install(false);
        assert_eq!(result, Err(ModelInstallerError::ChecksumMismatch));
        assert_eq!(fs::read(&pointer_path).unwrap(), pointer_before);
        assert!(old_installed.directory.exists());
        assert!(!root.join("supertonic-3").join(&new_manifest.revision).exists());

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn ureq_downloader_fetches_a_real_asset_over_https() {
        if std::env::var("DEBRIEF_TEST_NETWORK").is_err() {
            eprintln!("skipping: set DEBRIEF_TEST_NETWORK=1 to run a real network download test");
            return;
        }
        let manifest = ModelManifest::supertonic3();
        let asset = manifest.assets.iter().find(|a| a.relative_path == "onnx/tts.json").unwrap();
        let dir = temporary_directory();
        let destination = dir.join("tts.json");

        let downloader = UreqModelDownloader::new();
        downloader.download(asset, &destination).expect("real download must succeed");

        let data = fs::read(&destination).unwrap();
        assert_eq!(data.len() as u64, asset.byte_count);
        let mut hasher = Sha256::new();
        hasher.update(&data);
        let digest: String = hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(digest, asset.sha256);

        fs::remove_dir_all(&dir).ok();
    }
}
