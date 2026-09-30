# debrief Rust Rewrite — Foundation (Workspace, Paths, Configuration, Model Manifest) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Rust Cargo workspace (`debrief-core`, `debrief-tts`, `debrief` bin) and port the data-layer foundation everything else depends on: filesystem paths, persisted configuration, and the pinned model manifest — each with the same behavior and file formats as the current Swift implementation, verified by ported tests.

**Architecture:** Three crates in one Cargo workspace. `debrief-core` is the library crate holding paths, configuration, and model-manifest types (pure data + validation, no I/O side effects beyond what today's Swift equivalents do). `debrief-tts` is created empty in this plan (populated by a later plan) so the workspace topology is final from the start. `debrief` is the binary crate; in this plan it only prints a version string, proving the workspace links and the `Cargo.toml` topology is correct — the CLI itself is built out in a later plan.

**Tech Stack:** Rust (stable toolchain already installed: rustc/cargo 1.98.1), Cargo workspaces, `serde` + `serde_json` for persistence, `sha2` for manifest hashing (matches Swift's `CryptoKit.SHA256` usage), `dirs` is NOT used — `home` is passed explicitly everywhere, exactly like the Swift `DebriefPaths.forHome(_:)` pattern, so tests never touch the real `$HOME`.

**Spec:** `docs/superpowers/specs/2026-09-30-rust-rewrite-design.md`

## Global Constraints

- Target macOS 14+, Apple Silicon (`aarch64-apple-darwin`) for the shipped binary; the workspace itself must also `cargo build`/`cargo test` cleanly on the host running this plan (also arm64 macOS).
- File layout under `$HOME` must byte-for-byte match the current Swift layout: `~/Library/Application Support/debrief/{config.json,models/,install-manifest.json,session-voices.json}`, `~/Library/Caches/debrief/{debrief.sock,daemon.pid,last-error.json}`, `~/.local/bin/debrief`, `~/Library/LaunchAgents/com.debrief.tts.plist` — this plan defines the path struct; later plans rely on these exact fields.
- Config file permissions: directory `0o700`, file `0o600`, written atomically (temp file + `rename`), exactly as `DebriefConfiguration.save(to:)` does today.
- `ModelManifest` validation rules must be preserved exactly (see Task 3) — this manifest is embedded in the binary and any relaxation is a security regression (path traversal, non-pinned URLs).
- Follow TDD: write the failing test, watch it fail, write minimal code, watch it pass, commit.
- Do not add a config-file schema migration layer, a plugin system, or any generalization beyond what today's Swift code does. Port behavior 1:1; do not "improve" while porting.

## Review Focus

- **Corrupt or missing config.json** — `DebriefConfiguration::load` must return `Default::default()` silently (no panic, no error surfaced) exactly like Swift's `load(from:)`; a test loading a file containing `"not-json"` must not panic. Task 2 covers this.
- **Model manifest `relativePath` traversal** — an asset path like `"../etc/passwd"` or an absolute path `"/etc/passwd"` must be rejected by `validate()`; Swift's `ModelManifestError.invalidRelativePath` guards this. Task 3 covers this.
- **Model manifest mutable URL** — an asset URL that does not contain `/resolve/{revision}/` must be rejected (`ModelManifestError.mutableURL` in Swift) — this stops a manifest from silently being changed to point at a mutable HF `main` branch ref. Task 3 covers this.
- **Duplicate relative paths in one manifest** — two assets sharing the same `relativePath` must be rejected (`ModelManifestError.duplicateRelativePath`). Task 3 covers this.
- **Home path with trailing content that looks like another directory** — `DebriefPaths::for_home` must not accidentally escape the given `home` root (e.g., no `..` collapsing bugs); the ported test asserts every path stays prefixed with the exact home string. Task 1 covers this.

---

## File Structure

```text
Cargo.toml                          workspace manifest (members: crates/debrief-core, crates/debrief-tts, crates/debrief)
crates/debrief-core/
  Cargo.toml
  src/
    lib.rs                          re-exports paths, configuration, model_manifest modules
    paths.rs                        DebriefPaths (port of DebriefPaths.swift, minus currentExecutableURL — that moves to a later plan with the CLI)
    configuration.rs                DebriefConfiguration, DebriefMode, ConfigurationCommands (port of DebriefConfiguration.swift)
    model_manifest.rs                ModelAsset, ModelManifest, ModelManifestError, the embedded supertonic-3 manifest (port of ModelManifest.swift)
crates/debrief-tts/
  Cargo.toml
  src/lib.rs                        empty placeholder (`// populated by a later plan`), just enough for the workspace to build
crates/debrief/
  Cargo.toml
  src/main.rs                       prints "debrief 0.1.0" and exits 0 — proves the workspace links
```

---

### Task 1: Workspace scaffold + `DebriefPaths`

**Files:**
- Create: `Cargo.toml` (workspace root)
- Create: `crates/debrief-core/Cargo.toml`
- Create: `crates/debrief-core/src/lib.rs`
- Create: `crates/debrief-core/src/paths.rs`
- Create: `crates/debrief-tts/Cargo.toml`
- Create: `crates/debrief-tts/src/lib.rs`
- Create: `crates/debrief/Cargo.toml`
- Create: `crates/debrief/src/main.rs`
- Test: `crates/debrief-core/src/paths.rs` (inline `#[cfg(test)] mod tests`)

**Interfaces:**
- Produces: `pub struct DebriefPaths { pub home: PathBuf, pub data_directory: PathBuf, pub cache_directory: PathBuf, pub config_url: PathBuf, pub models_directory: PathBuf, pub socket_url: PathBuf, pub pid_url: PathBuf, pub executable_url: PathBuf, pub launch_agent_url: PathBuf, pub install_manifest_url: PathBuf, pub last_error_url: PathBuf, pub session_voices_url: PathBuf }` and `impl DebriefPaths { pub fn for_home(home: &Path) -> Self }`. Every later task/plan that needs a filesystem location goes through this struct.

- [ ] **Step 1: Create the workspace root `Cargo.toml`**

```toml
[workspace]
resolver = "2"
members = [
    "crates/debrief-core",
    "crates/debrief-tts",
    "crates/debrief",
]

[workspace.package]
version = "0.1.0"
edition = "2021"
```

- [ ] **Step 2: Create `crates/debrief-core/Cargo.toml`**

```toml
[package]
name = "debrief-core"
version.workspace = true
edition.workspace = true

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"

[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 3: Create `crates/debrief-core/src/lib.rs`**

```rust
pub mod configuration;
pub mod model_manifest;
pub mod paths;

pub use configuration::{ConfigurationCommandError, ConfigurationCommands, DebriefConfiguration, DebriefMode};
pub use model_manifest::{ModelAsset, ModelManifest, ModelManifestError};
pub use paths::DebriefPaths;
```

(This file will fail to compile until Tasks 2 and 3 create `configuration.rs` and `model_manifest.rs` — that's expected; Step 8 of this task only compiles `paths.rs` in isolation via `cargo test -p debrief-core paths::`.)

- [ ] **Step 4: Write the failing test in `crates/debrief-core/src/paths.rs`**

```rust
use std::path::{Path, PathBuf};

pub struct DebriefPaths {
    pub home: PathBuf,
    pub data_directory: PathBuf,
    pub cache_directory: PathBuf,
    pub config_url: PathBuf,
    pub models_directory: PathBuf,
    pub socket_url: PathBuf,
    pub pid_url: PathBuf,
    pub executable_url: PathBuf,
    pub launch_agent_url: PathBuf,
    pub install_manifest_url: PathBuf,
    pub last_error_url: PathBuf,
    pub session_voices_url: PathBuf,
}

impl DebriefPaths {
    pub fn for_home(home: &Path) -> Self {
        todo!()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_stay_under_the_provided_home() {
        let home = PathBuf::from("/Users/example");
        let paths = DebriefPaths::for_home(&home);

        assert_eq!(paths.data_directory, PathBuf::from("/Users/example/Library/Application Support/debrief"));
        assert_eq!(paths.cache_directory, PathBuf::from("/Users/example/Library/Caches/debrief"));
        assert_eq!(paths.config_url, PathBuf::from("/Users/example/Library/Application Support/debrief/config.json"));
        assert_eq!(paths.socket_url, PathBuf::from("/Users/example/Library/Caches/debrief/debrief.sock"));
        assert_eq!(paths.launch_agent_url, PathBuf::from("/Users/example/Library/LaunchAgents/com.debrief.tts.plist"));
        assert_eq!(paths.pid_url, PathBuf::from("/Users/example/Library/Caches/debrief/daemon.pid"));
        assert_eq!(paths.last_error_url, PathBuf::from("/Users/example/Library/Caches/debrief/last-error.json"));
        assert_eq!(paths.executable_url, PathBuf::from("/Users/example/.local/bin/debrief"));
        assert_eq!(paths.install_manifest_url, PathBuf::from("/Users/example/Library/Application Support/debrief/install-manifest.json"));
        assert_eq!(paths.models_directory, PathBuf::from("/Users/example/Library/Application Support/debrief/models"));
        assert_eq!(paths.session_voices_url, PathBuf::from("/Users/example/Library/Application Support/debrief/session-voices.json"));
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `cargo test -p debrief-core --lib paths::tests::paths_stay_under_the_provided_home`
Expected: FAIL — panics with `not yet implemented` (the `todo!()`).

- [ ] **Step 6: Implement `DebriefPaths::for_home`**

Replace the `todo!()` body:

```rust
impl DebriefPaths {
    pub fn for_home(home: &Path) -> Self {
        let data_directory = home.join("Library/Application Support/debrief");
        let cache_directory = home.join("Library/Caches/debrief");
        DebriefPaths {
            home: home.to_path_buf(),
            data_directory: data_directory.clone(),
            cache_directory: cache_directory.clone(),
            config_url: data_directory.join("config.json"),
            models_directory: data_directory.join("models"),
            socket_url: cache_directory.join("debrief.sock"),
            pid_url: cache_directory.join("daemon.pid"),
            executable_url: home.join(".local/bin/debrief"),
            launch_agent_url: home.join("Library/LaunchAgents/com.debrief.tts.plist"),
            install_manifest_url: data_directory.join("install-manifest.json"),
            last_error_url: cache_directory.join("last-error.json"),
            session_voices_url: data_directory.join("session-voices.json"),
        }
    }
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cargo test -p debrief-core --lib paths::tests::paths_stay_under_the_provided_home`
Expected: PASS

- [ ] **Step 8: Create the placeholder `debrief-tts` crate**

`crates/debrief-tts/Cargo.toml`:

```toml
[package]
name = "debrief-tts"
version.workspace = true
edition.workspace = true

[dependencies]
```

`crates/debrief-tts/src/lib.rs`:

```rust
// Populated by a later plan (Supertonic ONNX inference engine).
```

- [ ] **Step 9: Create the `debrief` binary crate skeleton**

`crates/debrief/Cargo.toml`:

```toml
[package]
name = "debrief"
version.workspace = true
edition.workspace = true

[[bin]]
name = "debrief"
path = "src/main.rs"

[dependencies]
debrief-core = { path = "../debrief-core" }
```

`crates/debrief/src/main.rs`:

```rust
fn main() {
    println!("debrief {}", env!("CARGO_PKG_VERSION"));
}
```

- [ ] **Step 10: Verify the whole workspace builds (this will still fail — `configuration` and `model_manifest` modules referenced in `lib.rs` don't exist yet)**

Run: `cargo build --workspace`
Expected: FAIL — `error[E0583]: file not found for module 'configuration'` and `'model_manifest'`. This confirms Task 1 is done and Tasks 2–3 are next; do not try to make this pass yet.

- [ ] **Step 11: Commit**

```bash
git add Cargo.toml crates/debrief-core/Cargo.toml crates/debrief-core/src/lib.rs crates/debrief-core/src/paths.rs crates/debrief-tts/Cargo.toml crates/debrief-tts/src/lib.rs crates/debrief/Cargo.toml crates/debrief/src/main.rs
git commit -m "feat(rust): scaffold Cargo workspace and port DebriefPaths"
```

---

### Task 2: `DebriefConfiguration` + `ConfigurationCommands`

**Files:**
- Create: `crates/debrief-core/src/configuration.rs`
- Modify: `crates/debrief-core/src/paths.rs` — none (already produced by Task 1)
- Test: `crates/debrief-core/src/configuration.rs` (inline `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: `debrief_core::paths::DebriefPaths` (`for_home`, `.config_url` field) from Task 1.
- Produces: `pub enum DebriefMode { Normal, Focus, Quiet, Verbose, Night }` with `#[serde(rename_all = "lowercase")]` so JSON round-trips as `"normal"`/`"focus"`/etc — matches Swift's `CaseIterable` raw values exactly. `pub struct DebriefConfiguration { pub mode: DebriefMode, pub muted: bool, pub companion_enabled: bool, pub volume_ceilings: HashMap<String, f64>, pub category_voices: HashMap<String, String>, pub voice_speeds: HashMap<String, f64> }` with `impl DebriefConfiguration { pub fn default_volume_ceilings() -> HashMap<String, f64>; pub fn load(url: &Path) -> Self; pub fn save(&self, url: &Path) -> std::io::Result<()> }`. `pub enum ConfigurationCommandError { InvalidMode(String), InvalidMuteAction(String), InvalidCompanionAction(String) }` and `pub struct ConfigurationCommands;` with `apply_mode`, `apply_mute`, `apply_companion` static methods taking `Option<&str>` and `home: &Path`, returning `Result<DebriefConfiguration, ConfigurationCommandError>`. Later plans (CLI `mode`/`mute`/`companion` subcommands) call these three functions directly.

- [ ] **Step 1: Write the failing tests**

```rust
use crate::paths::DebriefPaths;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

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
        todo!()
    }

    pub fn save(&self, url: &Path) -> std::io::Result<()> {
        todo!()
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

    fn temporary_directory() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("debrief-config-tests-{}", uuid_like()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn uuid_like() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        format!("{}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos())
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

        let mut first = DebriefConfiguration::default();
        first.mode = DebriefMode::Normal;
        first.muted = false;
        first.save(&url).unwrap();

        let mut second = DebriefConfiguration::default();
        second.mode = DebriefMode::Night;
        second.muted = true;
        second.save(&url).unwrap();

        assert_eq!(DebriefConfiguration::load(&url).mode, DebriefMode::Night);
        assert!(DebriefConfiguration::load(&url).muted);
        assert_eq!(permissions(&url), 0o600);
        assert_eq!(permissions(&url.parent().unwrap()), 0o700);
        let siblings: Vec<_> = fs::read_dir(url.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(siblings, vec![std::ffi::OsString::from("config.json")]);

        fs::remove_dir_all(&directory).ok();
    }
}
```

- [ ] **Step 2: Add `configuration` to `lib.rs` re-exports (already present from Task 1's Step 3) and run the tests to verify they fail**

Run: `cargo test -p debrief-core --lib configuration::tests`
Expected: FAIL — panics with `not yet implemented` from the two `todo!()` bodies.

- [ ] **Step 3: Implement `load` and `save`**

Replace the two `todo!()` bodies:

```rust
impl DebriefConfiguration {
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
        std::fs::write(&temporary, &data)?;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
        std::fs::rename(&temporary, url)?;
        Ok(())
    }
}
```

Note: the temp filename uses `process::id()` instead of a UUID crate dependency — this plan avoids adding a `uuid` dependency for a detail that only needs "unique enough within one process's lifetime," matching the spirit of Swift's `UUID().uuidString` without the extra crate. If a later plan already pulls in `uuid` for another reason, this can be revisited, but do not add the dependency here just for this.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p debrief-core --lib configuration::tests`
Expected: PASS (both tests)

- [ ] **Step 5: Verify the full crate builds now that `configuration.rs` exists**

Run: `cargo build -p debrief-core`
Expected: FAIL still — `model_manifest` module (Task 3) doesn't exist yet. This is expected; do not proceed to fix it in this task.

- [ ] **Step 6: Commit**

```bash
git add crates/debrief-core/src/configuration.rs
git commit -m "feat(rust): port DebriefConfiguration and ConfigurationCommands"
```

---

### Task 3: `ModelManifest` + embedded `supertonic-3` manifest

**Files:**
- Create: `crates/debrief-core/src/model_manifest.rs`
- Test: `crates/debrief-core/src/model_manifest.rs` (inline `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: nothing from Tasks 1–2 (this module is self-contained data + validation).
- Produces: `pub struct ModelAsset { pub relative_path: String, pub url: String, pub byte_count: u64, pub sha256: String }`, `pub struct ModelManifest { pub name: String, pub revision: String, pub assets: Vec<ModelAsset> }` with `impl ModelManifest { pub fn validate(&self) -> Result<(), ModelManifestError>; pub fn supertonic3() -> ModelManifest }`, and `#[derive(Debug, PartialEq)] pub enum ModelManifestError { InvalidName, InvalidRevision, EmptyAssets, InvalidRelativePath, DuplicateRelativePath, InvalidUrl, MutableUrl, InvalidByteCount, InvalidSha256 }`. A later plan (model downloader) calls `ModelManifest::supertonic3().validate()` then iterates `.assets` to fetch each one into `DebriefPaths.models_directory`.

- [ ] **Step 1: Write the failing tests**

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelAsset {
    pub relative_path: String,
    pub url: String,
    pub byte_count: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelManifest {
    pub name: String,
    pub revision: String,
    pub assets: Vec<ModelAsset>,
}

#[derive(Debug, PartialEq)]
pub enum ModelManifestError {
    InvalidName,
    InvalidRevision,
    EmptyAssets,
    InvalidRelativePath,
    DuplicateRelativePath,
    InvalidUrl,
    MutableUrl,
    InvalidByteCount,
    InvalidSha256,
}

impl ModelManifest {
    pub fn validate(&self) -> Result<(), ModelManifestError> {
        todo!()
    }

    pub fn supertonic3() -> ModelManifest {
        todo!()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_asset(path: &str) -> ModelAsset {
        ModelAsset {
            relative_path: path.to_string(),
            url: format!("https://huggingface.co/Supertone/supertonic-3/resolve/abcdef0123456789abcdef0123456789abcdef01/{path}"),
            byte_count: 100,
            sha256: "a".repeat(64),
        }
    }

    fn valid_manifest() -> ModelManifest {
        ModelManifest {
            name: "supertonic-3".to_string(),
            revision: "abcdef0123456789abcdef0123456789abcdef01".to_string(),
            assets: vec![valid_asset("onnx/tts.json")],
        }
    }

    #[test]
    fn valid_manifest_passes() {
        assert!(valid_manifest().validate().is_ok());
    }

    #[test]
    fn empty_name_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.name = String::new();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidName));
    }

    #[test]
    fn revision_with_path_traversal_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.revision = "..".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRevision));
    }

    #[test]
    fn revision_with_slash_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.revision = "abc/def".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRevision));
    }

    #[test]
    fn empty_assets_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets = vec![];
        assert_eq!(manifest.validate(), Err(ModelManifestError::EmptyAssets));
    }

    #[test]
    fn absolute_relative_path_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "/etc/passwd".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn relative_path_with_dot_dot_component_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "onnx/../../../etc/passwd".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn relative_path_with_backslash_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "onnx\\evil.onnx".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn duplicate_relative_paths_are_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets.push(valid_asset("onnx/tts.json"));
        assert_eq!(manifest.validate(), Err(ModelManifestError::DuplicateRelativePath));
    }

    #[test]
    fn non_https_url_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].url = "http://huggingface.co/Supertone/supertonic-3/resolve/abcdef0123456789abcdef0123456789abcdef01/onnx/tts.json".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidUrl));
    }

    #[test]
    fn url_not_pinned_to_revision_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].url = "https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/tts.json".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::MutableUrl));
    }

    #[test]
    fn zero_byte_count_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].byte_count = 0;
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidByteCount));
    }

    #[test]
    fn malformed_sha256_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].sha256 = "not-a-hash".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidSha256));
    }

    #[test]
    fn embedded_supertonic3_manifest_validates() {
        ModelManifest::supertonic3().validate().expect("embedded manifest must be valid");
    }

    #[test]
    fn embedded_supertonic3_manifest_matches_known_revision_and_asset_count() {
        let manifest = ModelManifest::supertonic3();
        assert_eq!(manifest.name, "supertonic-3");
        assert_eq!(manifest.revision, "3cadd1ee6394adea1bd021217a0e650ede09a323");
        assert_eq!(manifest.assets.len(), 16);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p debrief-core --lib model_manifest::tests`
Expected: FAIL — panics with `not yet implemented` from both `todo!()` bodies.

- [ ] **Step 3: Implement `validate()`**

Replace the `validate` `todo!()`:

```rust
impl ModelManifest {
    pub fn validate(&self) -> Result<(), ModelManifestError> {
        if self.name.is_empty() {
            return Err(ModelManifestError::InvalidName);
        }
        let revision_ok = !self.revision.is_empty()
            && self.revision.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
            && self.revision != "."
            && self.revision != ".."
            && !self.revision.contains('/');
        if !revision_ok {
            return Err(ModelManifestError::InvalidRevision);
        }
        if self.assets.is_empty() {
            return Err(ModelManifestError::EmptyAssets);
        }

        let mut seen_paths = std::collections::HashSet::new();
        for asset in &self.assets {
            let components: Vec<&str> = asset.relative_path.split('/').collect();
            let path_ok = !asset.relative_path.starts_with('/')
                && !asset.relative_path.contains('\\')
                && !components.is_empty()
                && components.iter().all(|c| !c.is_empty() && *c != "." && *c != "..");
            if !path_ok {
                return Err(ModelManifestError::InvalidRelativePath);
            }
            if !seen_paths.insert(asset.relative_path.clone()) {
                return Err(ModelManifestError::DuplicateRelativePath);
            }

            let is_https = asset.url.starts_with("https://");
            let has_host = asset.url.strip_prefix("https://").map(|rest| !rest.is_empty() && !rest.starts_with('/')).unwrap_or(false);
            if !is_https || !has_host {
                return Err(ModelManifestError::InvalidUrl);
            }
            if !asset.url.contains(&format!("/resolve/{}/", self.revision)) {
                return Err(ModelManifestError::MutableUrl);
            }
            if asset.byte_count == 0 {
                return Err(ModelManifestError::InvalidByteCount);
            }
            let sha_ok = asset.sha256.len() == 64 && asset.sha256.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase());
            if !sha_ok {
                return Err(ModelManifestError::InvalidSha256);
            }
        }
        Ok(())
    }
}
```

- [ ] **Step 4: Implement `supertonic3()` — port the exact asset list from `Sources/DebriefCore/ModelManifest.swift`**

Replace the `supertonic3` `todo!()`. Read `/Users/hmc7102758/Develop/Workspaces/debrief/Sources/DebriefCore/ModelManifest.swift` (already read during planning — the `assets:` array there is the source of truth) and transcribe every `asset(path, size, digest)` call into a Rust `ModelAsset` literal with the identical `path`, `byteCount`, and `sha256` values. The revision string and base URL are:

```rust
impl ModelManifest {
    pub fn supertonic3() -> ModelManifest {
        let revision = "3cadd1ee6394adea1bd021217a0e650ede09a323".to_string();
        let base = format!("https://huggingface.co/Supertone/supertonic-3/resolve/{revision}/");
        let asset = |path: &str, byte_count: u64, sha256: &str| ModelAsset {
            relative_path: path.to_string(),
            url: format!("{base}{path}"),
            byte_count,
            sha256: sha256.to_string(),
        };
        ModelManifest {
            name: "supertonic-3".to_string(),
            revision,
            assets: vec![
                asset("onnx/duration_predictor.onnx", 3_700_147, "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
                asset("onnx/text_encoder.onnx", 36_416_150, "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
                asset("onnx/vector_estimator.onnx", 256_534_781, "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
                asset("onnx/vocoder.onnx", 101_424_195, "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
                asset("onnx/tts.json", 8_253, "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
                asset("onnx/unicode_indexer.json", 277_676, "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"),
                asset("voice_styles/F1.json", 292_046, "bbdec6ee00231c2c742ad05483df5334cab3b52fda3ba38e6a07059c4563dbc2"),
                asset("voice_styles/F2.json", 292_423, "7c722c6a72707b1a77f035d67f0d1351ba187738e06f7683e8c72b1df3477fc6"),
                asset("voice_styles/F3.json", 290_794, "12f6ef2573baa2defa1128069cb59f203e3ab67c92af77b42df8a0e3a2f7c6ab"),
                asset("voice_styles/F4.json", 291_808, "c2fa764c1225a76dfc3e2c73e8aa4f70d9ee48793860eb34c295fff01c2e032b"),
                asset("voice_styles/F5.json", 291_479, "45966e73316415626cf41a7d1c6f3b4c70dbc1ba2bee5c1978ef0ce33244fc8d"),
                asset("voice_styles/M1.json", 291_748, "e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b"),
                asset("voice_styles/M2.json", 292_055, "b76cbf62bac707c710cf0ae5aba5e31eea1a6339a9734bfae33ab98499534a50"),
                asset("voice_styles/M3.json", 290_198, "ea1ac35ccb91b0d7ecad533a2fbd0eec10c91513d8951e3b25fbba99954e159b"),
                asset("voice_styles/M4.json", 291_522, "ca8eefad4fcd989c9379032ff3e50738adc547eeb5e221b82593a6d7b3bac303"),
                asset("voice_styles/M5.json", 291_469, "dd22b92740314321f8ae11c5e87f8dd60d060f15dd3a632b5adf77f471f77af2"),
            ],
        }
    }
}
```

Before running tests, diff this list against the live Swift source to catch any transcription error:

Run: `diff <(grep -oE '"[a-z_./]+\.(onnx|json)", [0-9_]+, "[0-9a-f]+"' /Users/hmc7102758/Develop/Workspaces/debrief/Sources/DebriefCore/ModelManifest.swift) <(grep -oE '"[a-z_./]+\.(onnx|json)", [0-9_]+, "[0-9a-f]+"' crates/debrief-core/src/model_manifest.rs)`
Expected: no output (the two asset lists are character-identical modulo the `asset(` call syntax already normalized by the grep pattern).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cargo test -p debrief-core --lib model_manifest::tests`
Expected: PASS (all 15 tests)

- [ ] **Step 6: Verify the full workspace builds now that all three `debrief-core` modules exist**

Run: `cargo build --workspace`
Expected: PASS. If it fails, the error will point at whichever `lib.rs` re-export doesn't match — fix the re-export names in `crates/debrief-core/src/lib.rs` to match the actual `pub` items in `configuration.rs`/`model_manifest.rs`/`paths.rs` (do not change the module files themselves).

- [ ] **Step 7: Run the full workspace test suite**

Run: `cargo test --workspace`
Expected: PASS — all tests from Tasks 1–3 pass together (18 tests total: 1 from `paths`, 2 from `configuration`, 15 from `model_manifest`). If the number printed differs, run `cargo test --workspace -- --list` and reconcile against the test functions actually written in Steps 1 of each task rather than trusting this count.

- [ ] **Step 8: Run the binary to confirm the workspace links end-to-end**

Run: `cargo run -p debrief`
Expected: prints `debrief 0.1.0` and exits 0.

- [ ] **Step 9: Commit**

```bash
git add crates/debrief-core/src/model_manifest.rs
git commit -m "feat(rust): port ModelManifest with validation and the embedded supertonic-3 manifest"
```

---

## What This Plan Does Not Cover

This plan stops at the data layer. It does not implement:

- The `debrief-tts` ONNX inference engine (next plan — depends on the `ModelManifest` types from this plan).
- Audio playback (`cpal`).
- The Unix socket server/client, speech queue, or daemon loop.
- The MCP stdio JSON-RPC server (`speak`/`install` tools, including the new `lang` parameter from the spec).
- Host installer (Claude/Codex/Grok hook and skill wiring), LaunchAgent control, or the `RuntimeInstaller`-equivalent (including the 0.0.5 BTM-throttle-avoidance logic, which must be ported, not re-derived).
- The `debrief` CLI subcommands beyond the version-printing stub in Task 1 (`install`, `daemon`, `start`, `stop`, `status`, `doctor`, `mute`, `mode`, `companion`, `hook`, `mcp`).
- The model downloader (`ModelInstaller.swift` equivalent — atomic asset download + checksum verification into `DebriefPaths.models_directory`).
- GitHub Actions release workflow and the Homebrew formula rewrite.

Each of these becomes its own plan once this foundation is merged, per the spec's crate boundaries (`debrief-core` for everything except inference, `debrief-tts` for the ONNX engine).
