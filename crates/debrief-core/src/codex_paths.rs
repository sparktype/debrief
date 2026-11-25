use std::path::{Path, PathBuf};

/// Codex configuration lives in CODEX_HOME; shared skills still live in ~/.agents/skills.
#[derive(Debug, Clone)]
pub struct CodexPaths {
    pub hooks_url: PathBuf,
    pub config_url: PathBuf,
}

impl CodexPaths {
    pub fn for_home(home: &Path) -> Self {
        Self::from_root(home.join(".codex"))
    }

    /// Resolve the process environment only at live CLI/MCP boundaries.
    pub fn from_environment(home: &Path) -> Self {
        match std::env::var_os("CODEX_HOME").filter(|value| !value.is_empty()) {
            Some(root) => Self::from_root(root.into()),
            None => Self::for_home(home),
        }
    }

    pub fn from_root(root: PathBuf) -> Self {
        Self {
            hooks_url: root.join("hooks.json"),
            config_url: root.join("config.toml"),
        }
    }
}
