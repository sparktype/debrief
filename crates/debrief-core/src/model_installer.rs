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
        todo!()
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
        todo!()
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
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

    pub fn install(&self, repair: bool) -> Result<InstalledModel, ModelInstallerError> {
        todo!()
    }
}
