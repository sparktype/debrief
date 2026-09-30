# debrief Rust Rewrite — Model Downloader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `ModelInstaller.swift` (atomic, checksum-verified, resumable download of the Supertonic model assets into `DebriefPaths.models_directory`) to Rust, using a synchronous HTTP client and the same atomic-staging-swap pattern the Swift version uses.

**Architecture:** One new file, `crates/debrief-core/src/model_installer.rs`, exposing a `ModelInstaller<D: ModelDownloading>` generic struct (mirrors the Swift generic-over-`ModelDownloading` pattern so tests can inject a fake downloader without any network I/O). `install(repair: bool)` validates the embedded manifest, downloads or reuses each asset into a staging directory, verifies each downloaded file's size and sha256, then atomically swaps the staging directory into place with `renameatx_np`, and finally writes/swaps a `current.json` pointer the same way. The real downloader (`UreqModelDownloader`) uses `ureq` with the `native-tls` provider (required for HMG's SSL-interception network — verified separately, see spec).

**Tech Stack:** Rust `ureq = "3"` (`default-features = false, features = ["native-tls"]`) for HTTP, `native-tls` crate for the `TlsProvider::NativeTls` config, `sha2` (already a `debrief-core` dependency, unused until now) for checksum verification, `libc` (new dependency) for `renameatx_np`/`RENAME_SWAP` FFI, `serde`/`serde_json` (already present) for the `current.json` pointer file.

**Spec:** `docs/superpowers/specs/2026-09-30-rust-rewrite-design.md` (§5 "설치 매니페스트/모델 다운로드" and the `native-tls` addendum)

## Global Constraints

- Target macOS 14+, Apple Silicon (`aarch64-apple-darwin`); this plan's code must also `cargo build`/`cargo test` cleanly on the arm64 macOS host running this plan.
- Every disk write in the install path must end up atomic and crash-safe, matching the Swift original: staging directory built fully before any swap, `renameatx_np` with `RENAME_SWAP` when a final path already exists, plain `rename` when it does not, fsync before any rename that matters for durability (Swift calls `try file.synchronize()` on the marker and pointer files before renaming — port this).
- `--repair` semantics: for each asset, if a valid copy already exists at the currently-active revision's path (right size AND right sha256), copy it into staging instead of re-downloading; otherwise download. This is a per-asset decision, not per-manifest.
- A checksum or size mismatch on any asset must abort the *entire* install before anything is swapped into place — the previously active revision (if any) must remain fully intact and `current.json` must be untouched. This is the single most important safety property in the Swift original (see `checksumFailurePreservesPreviouslyActiveRevision` in `SwiftTests/DebriefIntegrationTests/ModelInstallerTests.swift`) and must be preserved exactly.
- `ureq`'s TLS provider must be explicitly set to `native-tls`, not the crate default `rustls` — verified directly that `rustls` fails behind an SSL-interception proxy (`UnknownIssuer`) while `native-tls` (macOS Secure Transport / system keychain) succeeds. See spec addendum.
- No async runtime. Everything in this plan is synchronous `std`-based code — no `tokio`, no `async fn`.
- Do not add retry/backoff logic, resumable partial downloads, progress reporting, or parallel asset downloads — none of that exists in the Swift original and none of it is requested. Port behavior 1:1.

## Review Focus

- **Checksum mismatch on a repair/upgrade must not corrupt or delete the previously-installed working revision** — the Swift test `checksumFailurePreservesPreviouslyActiveRevision` locks this in; the Rust port needs an equivalent test that asserts both the old revision's directory and `current.json` are byte-identical to their pre-install state after a failed install. Task 4 covers this.
- **`--repair` must not re-download an asset that is already valid at its final location** — the Swift test `repairDownloadsOnlyMissingOrInvalidFiles` asserts the fake downloader's `requestedPaths` excludes the already-valid asset. The Rust port's fake downloader needs the same assertion. Task 3 covers this.
- **A downloaded file with the wrong byte count must be rejected before the sha256 check even runs** (cheap check first) — matches Swift's `validate(asset:at:)` order (size check, then hash). Task 2 covers this in the validate function; the test asserting rejection covers both size and hash mismatches independently.
- **The staging directory must never leak on any failure path** — Swift's `defer { if stagingNeedsRemoval { try? fileManager.removeItem(at: staging) } }` cleans up the staging directory unless the install fully succeeded. The Rust port needs the equivalent guaranteed cleanup (a Rust `Drop` guard, or explicit cleanup on every early-return path) — this is the kind of thing the fsync/cleanup gap in the earlier `DebriefConfiguration::save()` review missed, so this plan spells it out as its own task step rather than leaving it implicit. Task 2 covers this.
- **`native-tls` must actually be reachable when running behind the HMG SSL-interception proxy** — this is infrastructure-dependent and cannot be fully unit-tested, but Task 5 includes a manual verification step against a real Hugging Face URL from this development machine, since a previous throwaway experiment already proved `rustls` fails there and `native-tls` succeeds — the plan's actual downloader code needs the same one-time manual confirmation before this task is considered done.

---

## File Structure

```text
crates/debrief-core/
  Cargo.toml                        add ureq, native-tls, libc dependencies
  src/
    lib.rs                          add `pub mod model_installer;` + re-exports
    model_installer.rs               ModelDownloading trait, UreqModelDownloader,
                                     ModelInstaller<D>, ModelInstallerError,
                                     InstalledModel, CurrentModelPointer (private)
```

---

### Task 1: `Cargo.toml` dependencies + skeleton module

**Files:**
- Modify: `crates/debrief-core/Cargo.toml`
- Modify: `crates/debrief-core/src/lib.rs`
- Create: `crates/debrief-core/src/model_installer.rs`

**Interfaces:**
- Consumes: `debrief_core::model_manifest::{ModelAsset, ModelManifest}` (existing, from the foundation plan) and `debrief_core::paths::DebriefPaths` (existing) for `models_directory`.
- Produces: the module skeleton (types below, bodies as `todo!()`) that Tasks 2–4 fill in. Later tasks (CLI `install` subcommand) will call `ModelInstaller::new(paths.models_directory.clone(), ModelManifest::supertonic3(), UreqModelDownloader::new()).install(repair)`.

- [ ] **Step 1: Add dependencies to `crates/debrief-core/Cargo.toml`**

```toml
[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
ureq = { version = "3", default-features = false, features = ["native-tls"] }
native-tls = "0.2"
libc = "0.2"

[dev-dependencies]
tempfile = "3"
```

(Only the last three dependency lines and the `native-tls`/`libc` entries are new — `serde`/`serde_json`/`sha2`/`tempfile` already exist from the foundation plan; keep them as-is, just add the three new lines.)

- [ ] **Step 2: Add the module declaration to `crates/debrief-core/src/lib.rs`**

Add `pub mod model_installer;` alongside the existing `pub mod configuration;`, `pub mod model_manifest;`, `pub mod paths;` lines, and re-export the public types:

```rust
pub use model_installer::{
    InstalledModel, ModelDownloading, ModelInstaller, ModelInstallerError, UreqModelDownloader,
};
```

- [ ] **Step 3: Create the skeleton in `crates/debrief-core/src/model_installer.rs`**

```rust
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
```

- [ ] **Step 4: Verify the workspace compiles (expected to fail — that's fine, `todo!()` bodies are unreachable until called, but confirm there are no *type* errors)**

Run: `cargo build --workspace 2>&1`
Expected: succeeds (the `todo!()` bodies compile fine as long as they're not called; `cargo build` does not execute code). If you see a type error (not a warning), fix the skeleton to match the exact signatures above before moving on — do not proceed to Task 2 with a skeleton that doesn't compile.

- [ ] **Step 5: Commit**

```bash
git add crates/debrief-core/Cargo.toml crates/debrief-core/src/lib.rs crates/debrief-core/src/model_installer.rs
git commit -m "feat(rust): scaffold model_installer module with ureq/native-tls/libc deps"
```

---

### Task 2: Asset validation, staging, and atomic install — with a fake downloader

**Files:**
- Modify: `crates/debrief-core/src/model_installer.rs`
- Test: same file, inline `#[cfg(test)] mod tests`

**Interfaces:**
- Consumes: `ModelManifest`, `ModelAsset` (existing), the `ModelDownloading` trait from Task 1 (test uses a fake implementation, not `UreqModelDownloader`).
- Produces: a fully working `ModelInstaller::install(repair: bool) -> Result<InstalledModel, ModelInstallerError>` that works end-to-end against any `ModelDownloading` implementation — this is what Task 3's real network test and the later CLI `install` subcommand both call.

This task does NOT implement `UreqModelDownloader::download` (that's Task 3) — it implements everything else using a fake, in-memory downloader for tests, exactly like the Swift test suite's `FakeModelDownloader` (`SwiftTests/DebriefIntegrationTests/ModelInstallerTests.swift`).

- [ ] **Step 1: Write the failing tests**

Add to the `#[cfg(test)] mod tests` block (create it if Task 1 didn't leave one):

```rust
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
        let dir = std::env::temp_dir().join(format!(
            "debrief-model-installer-tests-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p debrief-core --lib model_installer::tests`
Expected: compile error or `todo!()` panic — `install`/`resolve_current`/the `UreqModelDownloader::download` stub aren't implemented yet. (Note: `installer.downloader.requested_paths()` accesses a private field for test convenience — if `downloader` isn't `pub(crate)` or accessible from the test module in the same file, either make the field visible within the module (it already is, since the test module is a child of this file) or restructure the assertion to take ownership of the downloader before constructing `ModelInstaller` and clone an `Arc` — prefer the simplest fix: since `mod tests` is inside `model_installer.rs`, it can already see private fields of types defined in the same file, so `installer.downloader.requested_paths()` should just work as long as `downloader` is a private (non-`pub`) field of `ModelInstaller`.)

- [ ] **Step 3: Implement `InstalledModel::resolve_current`**

```rust
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
```

- [ ] **Step 4: Implement asset validation helpers**

Add these as free functions or `impl<D: ModelDownloading> ModelInstaller<D>` associated functions (associated functions, matching the Swift `private static func`):

```rust
impl<D: ModelDownloading> ModelInstaller<D> {
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
}
```

Note: this reads the whole file into memory for hashing (fine for these asset sizes, up to ~256MB for `vector_estimator.onnx` — matches the Swift original's approach conceptually, though Swift streams in 1MB chunks via `FileHandle.read(upToCount:)`. If reading the full ~256MB file into memory in one `fs::read` call is a concern, stream instead using a `BufReader` and `Sha256::update` in a loop — but do not add this complexity unless `cargo test` or a real run shows it's actually a problem; start with the simple `fs::read` version).

- [ ] **Step 5: Implement `install()`**

```rust
impl<D: ModelDownloading> ModelInstaller<D> {
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

        if final_dir.exists() {
            let swapped = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    path_cstr(&staging).as_ptr(),
                    libc::AT_FDCWD,
                    path_cstr(&final_dir).as_ptr(),
                    libc::RENAME_SWAP as u32,
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
        let marker = staging.join(".validated.json");
        let data = serde_json::to_vec(&self.manifest).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        fs::write(&marker, data).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        Ok(())
    }

    fn write_current_pointer(&self, root: &Path) -> Result<(), ModelInstallerError> {
        let pointer = CurrentModelPointer {
            revision: self.manifest.revision.clone(),
            relative_path: self.manifest.revision.clone(),
        };
        let data = serde_json::to_vec(&pointer).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        let temporary = root.join(format!(".current-{}.json", std::process::id()));
        fs::write(&temporary, &data).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        let current = root.join("current.json");
        if current.exists() {
            let swapped = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    path_cstr(&temporary).as_ptr(),
                    libc::AT_FDCWD,
                    path_cstr(&current).as_ptr(),
                    libc::RENAME_SWAP as u32,
                )
            };
            if swapped != 0 {
                let _ = fs::remove_file(&temporary);
                return Err(ModelInstallerError::AtomicReplacementFailed);
            }
            let _ = fs::remove_file(&temporary);
        } else {
            fs::rename(&temporary, &current).map_err(|_| ModelInstallerError::AtomicReplacementFailed)?;
        }
        Ok(())
    }
}

fn path_cstr(path: &Path) -> std::ffi::CString {
    std::ffi::CString::new(path.as_os_str().to_str().unwrap()).unwrap()
}
```

Note on `#[derive(serde::Serialize, ...)]` on `CurrentModelPointer`: it needs `Serialize` too (Task 1's skeleton only had `Deserialize` implied by field access — check the derive line includes both `Serialize, Deserialize` from Task 1's Step 3; if not, add `Serialize` there). Also add `#[derive(serde::Serialize)]` to `ModelManifest` and `ModelAsset` if not already derived from the foundation plan (they should already have it — confirm by checking `crates/debrief-core/src/model_manifest.rs`, do not re-derive if already present).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cargo test -p debrief-core --lib model_installer::tests`
Expected: PASS (both tests)

- [ ] **Step 7: Commit**

```bash
git add crates/debrief-core/src/model_installer.rs
git commit -m "feat(rust): implement ModelInstaller atomic install/repair logic against a fake downloader"
```

---

### Task 3: Real `UreqModelDownloader` implementation

**Files:**
- Modify: `crates/debrief-core/src/model_installer.rs`
- Test: same file, extend `#[cfg(test)] mod tests` with a network-dependent test marked to skip by default

**Interfaces:**
- Consumes: `ModelDownloading` trait (Task 1), `ModelAsset` (existing).
- Produces: a working `UreqModelDownloader` that `debrief`'s future CLI `install` subcommand constructs via `UreqModelDownloader::new()`.

- [ ] **Step 1: Implement `UreqModelDownloader::download`**

Replace the `todo!()` body from Task 1:

```rust
impl ModelDownloading for UreqModelDownloader {
    fn download(&self, asset: &ModelAsset, destination: &Path) -> Result<(), ModelInstallerError> {
        use ureq::tls::{TlsConfig, TlsProvider};

        let tls_config = TlsConfig::builder().provider(TlsProvider::NativeTls).build();
        let config = ureq::Agent::config_builder().tls_config(tls_config).build();
        let agent = ureq::Agent::new_with_config(config);

        let mut response = agent
            .get(&asset.url)
            .call()
            .map_err(|_| ModelInstallerError::DownloadFailed)?;

        let mut file = std::fs::File::create(destination).map_err(|_| ModelInstallerError::DownloadFailed)?;
        std::io::copy(&mut response.body_mut().as_reader(), &mut file)
            .map_err(|_| ModelInstallerError::DownloadFailed)?;

        // Match Swift's chmod 0600 + fsync-before-close on the downloaded asset.
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(destination, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| ModelInstallerError::DownloadFailed)?;
        file.sync_all().map_err(|_| ModelInstallerError::DownloadFailed)?;
        Ok(())
    }
}
```

- [ ] **Step 2: Add a network-dependent smoke test, gated behind an env var (mirrors the Swift `DEBRIEF_TEST_MODEL_DIR` pattern used for real-model integration tests — this plan's equivalent gate is `DEBRIEF_TEST_NETWORK`)**

```rust
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
```

- [ ] **Step 3: Run the gated test to verify the real downloader works, including behind an SSL-interception proxy if this development machine is behind one**

Run: `DEBRIEF_TEST_NETWORK=1 cargo test -p debrief-core --lib model_installer::tests::ureq_downloader_fetches_a_real_asset_over_https -- --nocapture`
Expected: PASS, with the downloaded file's size and sha256 matching the embedded manifest's `onnx/tts.json` entry exactly (8253 bytes, `42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09`). If this fails with a TLS/certificate error, the `native-tls` provider config in Step 1 is wrong or missing — do not fall back to disabling certificate verification; fix the provider config instead.

- [ ] **Step 4: Run the full non-network test suite once more to confirm nothing broke**

Run: `cargo test -p debrief-core --lib model_installer::tests` (without `DEBRIEF_TEST_NETWORK` set)
Expected: PASS, with the network test printing its skip message and not failing.

- [ ] **Step 5: Commit**

```bash
git add crates/debrief-core/src/model_installer.rs
git commit -m "feat(rust): implement UreqModelDownloader with native-tls and a gated real-network test"
```

---

### Task 4: Full workspace verification + `debrief-core` re-export audit

**Files:**
- Modify: `crates/debrief-core/src/lib.rs` (only if the audit in Step 1 finds a missing re-export)
- No new files.

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing new — this task only verifies the crate's public surface is coherent and the whole workspace is green.

- [ ] **Step 1: Audit `crates/debrief-core/src/lib.rs`'s re-exports against what a later CLI-wiring plan will need**

Read the current `lib.rs`. Confirm it re-exports `ModelInstaller`, `ModelDownloading`, `UreqModelDownloader`, `ModelInstallerError`, `InstalledModel` (from Task 1's Step 2). If any is missing, add it.

- [ ] **Step 2: Run the full workspace build and test suite**

Run: `cargo build --workspace && cargo test --workspace`
Expected: PASS. All tests from the foundation plan (paths, configuration, model_manifest — 19 tests) plus this plan's new tests (`repair_downloads_only_missing_or_invalid_files`, `checksum_failure_preserves_previously_active_revision`, and the gated `ureq_downloader_fetches_a_real_asset_over_https` which will skip without `DEBRIEF_TEST_NETWORK`) must all pass.

- [ ] **Step 3: Run clippy**

Run: `cargo clippy --workspace --all-targets 2>&1`
Expected: zero warnings. Fix any that appear before proceeding — do not leave clippy warnings for a later plan to clean up, per the pattern already established in the foundation plan's final review.

- [ ] **Step 4: Commit (only if Step 1 required a fix; otherwise this task has no commit — note that in the task's completion)**

```bash
git add crates/debrief-core/src/lib.rs
git commit -m "chore(rust): re-export model_installer public types"
```

---

## What This Plan Does Not Cover

- The `debrief` binary's `install` CLI subcommand actually calling `ModelInstaller` — that's the CLI-wiring plan, which also needs `RuntimeInstaller`, `HostInstaller`, and the LaunchAgent bootstrap logic from the spec's §3.
- `InstallManifest` (owned-file/hook tracking) — a separate, small data-structure port, not covered here since nothing in this plan needs it.
- The TTS inference engine, audio playback, daemon/socket server, or MCP server — all separate plans per the spec's crate boundaries.
- Any Linux/systemd downloader variant — `UreqModelDownloader` itself is already platform-neutral (it's the atomic-rename logic using `libc::renameatx_np` that is macOS-only, and that's already flagged as a future `PlatformServiceManager`-style abstraction point in the spec, not something this plan needs to generalize now).
