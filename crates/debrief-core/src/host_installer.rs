// 호스트별(Claude/Codex/Grok) 훅·MCP·스킬 설치/제거 — 기존 설정은 보존하고 소유분만 교체
use crate::embedded_templates::EmbeddedTemplates;
use crate::hook_event::{HookEventName, HostSource};
use crate::install_manifest::{AtomicInstallerFile, InstallManifest, InstallerDigest, OwnedHook, OwnedInstalledFile};
use crate::mcp_toml_config::McpTomlConfig;
use crate::paths::DebriefPaths;
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub enum HostInstallerError {
    SettingsRootMustBeObject,
    HooksMustBeObject,
    EventHooksMustBeArray(String),
    Io,
}

impl From<std::io::Error> for HostInstallerError {
    fn from(_: std::io::Error) -> Self {
        HostInstallerError::Io
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostInstallResult {
    pub codex_review_required: bool,
    pub preserved_modified_files: Vec<String>,
}

pub struct HostInstaller {
    home: PathBuf,
    executable: PathBuf,
    manifest_url: PathBuf,
}

impl HostInstaller {
    pub fn new(home: PathBuf, executable: PathBuf, manifest_url: Option<PathBuf>) -> Self {
        let manifest_url = manifest_url.unwrap_or_else(|| DebriefPaths::for_home(&home).install_manifest_url);
        HostInstaller { home, executable, manifest_url }
    }

    /// JSON/TOML MCP 등록 다이제스트를 위한 합성 소유권 경로
    pub fn mcp_ownership_path(host: HostSource) -> String {
        format!("mcp:{}:debrief", host.as_str())
    }

    pub fn install(&self, hosts: &HashSet<HostSource>) -> Result<HostInstallResult, HostInstallerError> {
        let mut manifest = InstallManifest::load(&self.manifest_url).map_err(|_| HostInstallerError::Io)?;
        let mut preserved: Vec<String> = Vec::new();

        let mut sorted_hosts: Vec<_> = hosts.iter().copied().collect();
        sorted_hosts.sort_by_key(|h| h.as_str());

        for host in sorted_hosts {
            let previous_files: Vec<_> = manifest.files.iter().filter(|f| f.host == host).cloned().collect();
            let previous_hooks: Vec<_> = manifest.hooks.iter().filter(|h| h.host == host).cloned().collect();
            let mut owned_hooks: Vec<OwnedHook> = Vec::new();
            let mut owned_files: Vec<OwnedInstalledFile> = Vec::new();

            match host {
                HostSource::Codex => {
                    self.install_json_host(host, &previous_files, &previous_hooks, &mut owned_hooks, &mut owned_files, &mut preserved)?;
                    self.install_toml_mcp(HostSource::Codex, &previous_files, &mut owned_files, &mut preserved)?;
                }
                HostSource::Claude => {
                    self.install_json_host(host, &previous_files, &previous_hooks, &mut owned_hooks, &mut owned_files, &mut preserved)?;
                    self.install_claude_mcp(&previous_files, &mut owned_files, &mut preserved)?;
                }
                HostSource::Grok => {
                    self.install_grok_host(&previous_files, &mut owned_files, &mut preserved)?;
                }
            }

            manifest.hooks.retain(|h| h.host != host);
            manifest.hooks.extend(owned_hooks);
            manifest.files.retain(|f| f.host != host);
            manifest.files.extend(owned_files);
        }
        manifest.save(&self.manifest_url).map_err(|_| HostInstallerError::Io)?;
        preserved.sort();
        Ok(HostInstallResult { codex_review_required: hosts.contains(&HostSource::Codex), preserved_modified_files: preserved })
    }

    pub fn uninstall(&self, hosts: &HashSet<HostSource>) -> Result<HostInstallResult, HostInstallerError> {
        let mut manifest = InstallManifest::load(&self.manifest_url).map_err(|_| HostInstallerError::Io)?;
        let mut preserved: Vec<String> = Vec::new();

        let mut sorted_hosts: Vec<_> = hosts.iter().copied().collect();
        sorted_hosts.sort_by_key(|h| h.as_str());

        for host in sorted_hosts {
            match host {
                HostSource::Codex => {
                    self.uninstall_json_host(host, &manifest, &mut preserved)?;
                    self.uninstall_toml_mcp(HostSource::Codex, &manifest, &mut preserved)?;
                }
                HostSource::Claude => {
                    self.uninstall_json_host(host, &manifest, &mut preserved)?;
                    self.uninstall_claude_mcp(&manifest, &mut preserved)?;
                }
                HostSource::Grok => {
                    self.uninstall_grok_host(&manifest, &mut preserved)?;
                }
            }
            manifest.hooks.retain(|h| h.host != host);
            manifest.files.retain(|f| f.host != host);
        }
        manifest.save(&self.manifest_url).map_err(|_| HostInstallerError::Io)?;
        preserved.sort();
        Ok(HostInstallResult { codex_review_required: false, preserved_modified_files: preserved })
    }

    // MARK: - JSON hosts (Codex hooks / Claude settings + ~/.claude.json MCP)

    fn install_json_host(
        &self,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
        previous_hooks: &[OwnedHook],
        owned_hooks: &mut Vec<OwnedHook>,
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let settings_url = self.settings_url(host);
        let mut root = Self::read_settings(&settings_url)?;
        let mut hooks = Self::hooks_object(&root)?;

        // repair 시 이전에 소유했던 Stop/SubagentStop(및 폐지된 이벤트)을 제거한다.
        let active_events: HashSet<HookEventName> = EmbeddedTemplates::HOOK_EVENTS.into_iter().collect();
        for owned in previous_hooks.iter().filter(|owned| !active_events.contains(&owned.event)) {
            let mut entries = Self::event_entries(owned.event, &hooks)?;
            entries.retain(|entry| InstallerDigest::json(entry).ok().as_deref() != Some(owned.sha256.as_str()));
            if entries.is_empty() {
                hooks.remove(Self::event_key(owned.event));
            } else {
                hooks.insert(Self::event_key(owned.event).to_string(), Value::Array(entries));
            }
        }

        for event in EmbeddedTemplates::HOOK_EVENTS {
            let entry = EmbeddedTemplates::hook_entry(&self.executable, host);
            let object = Self::hook_entry_json(&entry);
            let digest = InstallerDigest::json(&object).map_err(|_| HostInstallerError::Io)?;
            let mut entries = Self::event_entries(event, &hooks)?;
            let already_present = entries
                .iter()
                .any(|existing| InstallerDigest::json(existing).ok().as_deref() == Some(digest.as_str()));
            if !already_present {
                entries.push(object);
            }
            hooks.insert(Self::event_key(event).to_string(), Value::Array(entries));
            owned_hooks.push(OwnedHook { host, event, sha256: digest });
        }
        root.insert("hooks".to_string(), Value::Object(hooks));

        // Claude Code는 settings.json의 mcpServers를 무시한다(사용자 MCP는 ~/.claude.json에
        // 산다) — 과거 설치가 여기 남겼을 debrief 항목은 낡은 것이므로 제거한다.
        self.strip_legacy_json_mcp_if_owned(&mut root, host, previous_files)?;

        Self::backup_if_needed(&settings_url)?;
        Self::write_settings(&root, &settings_url)?;

        self.install_skills(host, previous_files, owned_files, preserved)?;
        Ok(())
    }

    fn install_claude_mcp(
        &self,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let url = self.claude_user_config_url();
        let mut root = Self::read_settings(&url)?;
        self.merge_json_mcp(&mut root, HostSource::Claude, previous_files, owned_files, preserved)?;
        Self::backup_if_needed(&url)?;
        Self::write_settings(&root, &url)?;
        Ok(())
    }

    fn merge_json_mcp(
        &self,
        root: &mut Map<String, Value>,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let mcp_path = Self::mcp_ownership_path(host);
        let registration = Self::mcp_registration_json(&self.executable);
        let digest = InstallerDigest::json(&registration).map_err(|_| HostInstallerError::Io)?;
        let mut mcp_servers = match root.get("mcpServers") {
            Some(Value::Object(map)) => map.clone(),
            _ => Map::new(),
        };

        if let Some(existing) = mcp_servers.get("debrief").cloned() {
            let current = InstallerDigest::json(&existing).map_err(|_| HostInstallerError::Io)?;
            let previously_owned = previous_files.iter().any(|f| f.path == mcp_path && f.sha256 == current);
            if current != digest && !previously_owned {
                preserved.push(mcp_path.clone());
                if let Some(previous) = previous_files.iter().find(|f| f.path == mcp_path) {
                    owned_files.push(previous.clone());
                }
            } else {
                mcp_servers.insert("debrief".to_string(), registration);
                owned_files.push(OwnedInstalledFile { host, path: mcp_path, sha256: digest });
            }
        } else {
            mcp_servers.insert("debrief".to_string(), registration);
            owned_files.push(OwnedInstalledFile { host, path: mcp_path, sha256: digest });
        }
        root.insert("mcpServers".to_string(), Value::Object(mcp_servers));
        Ok(())
    }

    /// Codex hooks.json / Claude settings.json에 남은 JSON `mcpServers.debrief` 항목을 제거한다 —
    /// Codex MCP는 `config.toml`에, Claude MCP는 `~/.claude.json`에 살므로 그런 항목은 낡은 것이다.
    fn strip_legacy_json_mcp_if_owned(
        &self,
        root: &mut Map<String, Value>,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
    ) -> Result<(), HostInstallerError> {
        let Some(Value::Object(mcp_servers)) = root.get("mcpServers").cloned() else { return Ok(()) };
        let mut mcp_servers = mcp_servers;
        let mut changed = false;
        if let Some(existing) = mcp_servers.get("debrief").cloned() {
            let mcp_path = Self::mcp_ownership_path(host);
            let current = InstallerDigest::json(&existing).map_err(|_| HostInstallerError::Io)?;
            let registration_digest = InstallerDigest::json(&Self::mcp_registration_json(&self.executable))
                .map_err(|_| HostInstallerError::Io)?;
            let was_owned = previous_files.iter().any(|f| f.path == mcp_path && f.sha256 == current);
            if current == registration_digest || was_owned {
                mcp_servers.remove("debrief");
                changed = true;
            }
        }
        if changed {
            root.insert("mcpServers".to_string(), Value::Object(mcp_servers));
        }
        Ok(())
    }

    fn uninstall_json_host(
        &self,
        host: HostSource,
        manifest: &InstallManifest,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let settings_url = self.settings_url(host);
        if settings_url.exists() {
            let mut root = Self::read_settings(&settings_url)?;
            let mut hooks = Self::hooks_object(&root)?;
            for owned in manifest.hooks.iter().filter(|owned| owned.host == host) {
                let mut entries = Self::event_entries(owned.event, &hooks)?;
                entries.retain(|entry| InstallerDigest::json(entry).ok().as_deref() != Some(owned.sha256.as_str()));
                if entries.is_empty() {
                    hooks.remove(Self::event_key(owned.event));
                } else {
                    hooks.insert(Self::event_key(owned.event).to_string(), Value::Array(entries));
                }
            }
            root.insert("hooks".to_string(), Value::Object(hooks));

            let previous: Vec<_> = manifest.files.iter().filter(|f| f.host == host).cloned().collect();
            self.strip_legacy_json_mcp_if_owned(&mut root, host, &previous)?;

            Self::write_settings(&root, &settings_url)?;
        }

        for owned in manifest.files.iter().filter(|f| f.host == host) {
            if owned.path.starts_with("mcp:") {
                continue;
            }
            Self::remove_owned_file(owned, preserved)?;
        }
        Ok(())
    }

    fn uninstall_claude_mcp(&self, manifest: &InstallManifest, preserved: &mut Vec<String>) -> Result<(), HostInstallerError> {
        let url = self.claude_user_config_url();
        let mcp_path = Self::mcp_ownership_path(HostSource::Claude);
        if !url.exists() {
            return Ok(());
        }
        let Some(owned) = manifest.files.iter().find(|f| f.host == HostSource::Claude && f.path == mcp_path) else {
            return Ok(());
        };
        let mut root = Self::read_settings(&url)?;
        let Some(Value::Object(mcp_servers)) = root.get("mcpServers").cloned() else { return Ok(()) };
        let mut mcp_servers = mcp_servers;
        let Some(existing) = mcp_servers.get("debrief").cloned() else { return Ok(()) };
        if InstallerDigest::json(&existing).ok().as_deref() == Some(owned.sha256.as_str()) {
            mcp_servers.remove("debrief");
            root.insert("mcpServers".to_string(), Value::Object(mcp_servers));
            Self::write_settings(&root, &url)?;
        } else {
            preserved.push(mcp_path);
        }
        Ok(())
    }

    // MARK: - TOML MCP (Codex config.toml / Grok config.toml)

    fn install_toml_mcp(
        &self,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let config_url = self.mcp_toml_config_url(host);
        let mcp_path = Self::mcp_ownership_path(host);
        let fragment = EmbeddedTemplates::mcp_toml_fragment(&self.executable).trim_matches('\n').to_string();
        let digest = InstallerDigest::data(fragment.as_bytes());
        let existing = if config_url.exists() { fs::read_to_string(&config_url)? } else { String::new() };

        let mut should_write_config = true;
        if let Some(current_fragment) = McpTomlConfig::owned_fragment(&existing) {
            let current = InstallerDigest::data(current_fragment.as_bytes());
            let previously_owned = previous_files.iter().any(|f| f.path == mcp_path && f.sha256 == current);
            if current != digest && !previously_owned {
                preserved.push(config_url.to_string_lossy().to_string());
                if let Some(previous) = previous_files.iter().find(|f| f.path == mcp_path) {
                    owned_files.push(previous.clone());
                }
                should_write_config = false;
            }
        } else if McpTomlConfig::has_debrief_table(&existing) && !McpTomlConfig::has_markers(&existing) {
            // 소유하지 않는 외부 테이블 — 덮어쓰지 않는다.
            preserved.push(config_url.to_string_lossy().to_string());
            if let Some(previous) = previous_files.iter().find(|f| f.path == mcp_path) {
                owned_files.push(previous.clone());
            }
            should_write_config = false;
        }

        if should_write_config {
            Self::backup_if_needed(&config_url)?;
            let merged = McpTomlConfig::upsert(&existing, &fragment);
            AtomicInstallerFile::write(merged.as_bytes(), &config_url, 0o600)?;
            owned_files.push(OwnedInstalledFile { host, path: mcp_path, sha256: digest });
        }
        Ok(())
    }

    fn uninstall_toml_mcp(
        &self,
        host: HostSource,
        manifest: &InstallManifest,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let config_url = self.mcp_toml_config_url(host);
        let mcp_path = Self::mcp_ownership_path(host);
        if config_url.exists() {
            if let Some(owned) = manifest.files.iter().find(|f| f.host == host && f.path == mcp_path) {
                let existing = fs::read_to_string(&config_url)?;
                if let Some(current_fragment) = McpTomlConfig::owned_fragment(&existing) {
                    let current = InstallerDigest::data(current_fragment.as_bytes());
                    if current == owned.sha256 {
                        let cleaned = McpTomlConfig::remove_owned(&existing);
                        AtomicInstallerFile::write(cleaned.as_bytes(), &config_url, 0o600)?;
                    } else {
                        preserved.push(config_url.to_string_lossy().to_string());
                    }
                }
                // 마커가 사라졌으면 소유권을 조용히 포기한다(지울 것이 없음).
            }
        }
        Ok(())
    }

    // MARK: - Grok (TOML MCP + full skill set; no hooks)

    fn install_grok_host(
        &self,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        self.install_toml_mcp(HostSource::Grok, previous_files, owned_files, preserved)?;

        // Grok SessionStart는 컨텍스트를 주입할 수 없다 — setup/install/speak 스킬이 계약을 담당한다.
        let templates: std::collections::HashMap<_, _> =
            EmbeddedTemplates::grok_skills(&self.executable).into_iter().collect();
        for name in EmbeddedTemplates::SKILL_NAMES {
            let Some(text) = templates.get(name) else { continue };
            let destination = self.skills_directory(HostSource::Grok).join(format!("debrief-{name}/SKILL.md"));
            self.install_skill_file(text, &destination, HostSource::Grok, previous_files, owned_files, preserved)?;
        }
        Ok(())
    }

    fn uninstall_grok_host(
        &self,
        manifest: &InstallManifest,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        self.uninstall_toml_mcp(HostSource::Grok, manifest, preserved)?;

        for owned in manifest.files.iter().filter(|f| f.host == HostSource::Grok) {
            if owned.path.starts_with("mcp:") {
                continue;
            }
            Self::remove_owned_file(owned, preserved)?;
        }
        Ok(())
    }

    // MARK: - Shared helpers

    fn install_skills(
        &self,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let templates: std::collections::HashMap<_, _> = EmbeddedTemplates::skills(&self.executable).into_iter().collect();
        for name in EmbeddedTemplates::SKILL_NAMES {
            let Some(text) = templates.get(name) else { continue };
            let destination = self.skills_directory(host).join(format!("debrief-{name}/SKILL.md"));
            self.install_skill_file(text, &destination, host, previous_files, owned_files, preserved)?;
        }
        Ok(())
    }

    fn install_skill_file(
        &self,
        text: &str,
        destination: &Path,
        host: HostSource,
        previous_files: &[OwnedInstalledFile],
        owned_files: &mut Vec<OwnedInstalledFile>,
        preserved: &mut Vec<String>,
    ) -> Result<(), HostInstallerError> {
        let data = text.as_bytes();
        let digest = InstallerDigest::data(data);
        let destination_str = destination.to_string_lossy().to_string();
        if destination.exists() {
            let current = InstallerDigest::data(&fs::read(destination)?);
            let previously_owned = previous_files.iter().any(|f| f.path == destination_str && f.sha256 == current);
            if current != digest && !previously_owned {
                preserved.push(destination_str.clone());
                if let Some(previous) = previous_files.iter().find(|f| f.path == destination_str) {
                    owned_files.push(previous.clone());
                }
                return Ok(());
            }
        }
        AtomicInstallerFile::write(data, destination, 0o600)?;
        owned_files.push(OwnedInstalledFile { host, path: destination_str, sha256: digest });
        Ok(())
    }

    fn remove_owned_file(owned: &OwnedInstalledFile, preserved: &mut Vec<String>) -> Result<(), HostInstallerError> {
        let path = Path::new(&owned.path);
        if !path.exists() {
            return Ok(());
        }
        let current = InstallerDigest::data(&fs::read(path)?);
        if current == owned.sha256 {
            fs::remove_file(path)?;
        } else {
            preserved.push(owned.path.clone());
        }
        Ok(())
    }

    /// 훅/설정 JSON 경로 (Codex hooks, Claude settings). Grok은 TOML만 쓴다.
    fn settings_url(&self, host: HostSource) -> PathBuf {
        match host {
            HostSource::Codex => self.home.join(".codex/hooks.json"),
            HostSource::Claude => self.home.join(".claude/settings.json"),
            HostSource::Grok => self.home.join(".grok/config.toml"),
        }
    }

    /// Codex / Grok 네이티브 MCP 설정 경로 (TOML).
    fn mcp_toml_config_url(&self, host: HostSource) -> PathBuf {
        match host {
            HostSource::Codex => self.home.join(".codex/config.toml"),
            HostSource::Grok => self.home.join(".grok/config.toml"),
            HostSource::Claude => unreachable!("Claude MCP is JSON in ~/.claude.json"),
        }
    }

    /// Claude Code 사용자 범위 설정 — 사용자 MCP 서버를 읽는 유일한 곳.
    fn claude_user_config_url(&self) -> PathBuf {
        self.home.join(".claude.json")
    }

    fn skills_directory(&self, host: HostSource) -> PathBuf {
        match host {
            HostSource::Codex => self.home.join(".agents/skills"),
            HostSource::Claude => self.home.join(".claude/skills"),
            HostSource::Grok => self.home.join(".grok/skills"),
        }
    }

    fn read_settings(url: &Path) -> Result<Map<String, Value>, HostInstallerError> {
        if !url.exists() {
            return Ok(Map::new());
        }
        let data = fs::read(url)?;
        match serde_json::from_slice::<Value>(&data) {
            Ok(Value::Object(root)) => Ok(root),
            _ => Err(HostInstallerError::SettingsRootMustBeObject),
        }
    }

    fn hooks_object(root: &Map<String, Value>) -> Result<Map<String, Value>, HostInstallerError> {
        match root.get("hooks") {
            None => Ok(Map::new()),
            Some(Value::Object(hooks)) => Ok(hooks.clone()),
            Some(_) => Err(HostInstallerError::HooksMustBeObject),
        }
    }

    fn event_key(event: HookEventName) -> &'static str {
        event.as_str()
    }

    fn event_entries(event: HookEventName, hooks: &Map<String, Value>) -> Result<Vec<Value>, HostInstallerError> {
        match hooks.get(Self::event_key(event)) {
            None => Ok(Vec::new()),
            Some(Value::Array(entries)) => Ok(entries.clone()),
            Some(_) => Err(HostInstallerError::EventHooksMustBeArray(Self::event_key(event).to_string())),
        }
    }

    fn hook_entry_json(entry: &crate::embedded_templates::EmbeddedHookEntry) -> Value {
        serde_json::json!({
            "hooks": entry
                .hooks
                .iter()
                .map(|h| serde_json::json!({"type": h.r#type, "command": h.command, "timeout": h.timeout}))
                .collect::<Vec<_>>(),
        })
    }

    fn mcp_registration_json(executable: &Path) -> Value {
        let (command, args) = EmbeddedTemplates::mcp_registration(executable);
        serde_json::json!({"command": command, "args": args})
    }

    fn backup_if_needed(url: &Path) -> Result<(), HostInstallerError> {
        let mut backup_name = url.file_name().unwrap().to_os_string();
        backup_name.push(".debrief-backup");
        let backup = url.with_file_name(backup_name);
        if url.exists() && !backup.exists() {
            AtomicInstallerFile::write(&fs::read(url)?, &backup, 0o600)?;
        }
        Ok(())
    }

    fn write_settings(root: &Map<String, Value>, url: &Path) -> Result<(), HostInstallerError> {
        let data = serde_json::to_vec_pretty(root).map_err(|_| HostInstallerError::Io)?;
        AtomicInstallerFile::write(&data, url, 0o600)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::install_manifest::OwnedRuntimeFile;

    fn temporary_home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = std::env::temp_dir().join(format!("debrief-host-tests-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    fn write_json(value: &Value, url: &Path) {
        fs::create_dir_all(url.parent().unwrap()).unwrap();
        fs::write(url, serde_json::to_vec_pretty(value).unwrap()).unwrap();
    }

    fn json_at(url: &Path) -> Value {
        serde_json::from_slice(&fs::read(url).unwrap()).unwrap()
    }

    fn all_hosts() -> HashSet<HostSource> {
        [HostSource::Codex, HostSource::Claude, HostSource::Grok].into_iter().collect()
    }

    #[test]
    fn install_preserves_settings_backs_up_and_does_not_duplicate() {
        let home = temporary_home();
        let codex = home.join(".codex/hooks.json");
        let codex_config = home.join(".codex/config.toml");
        let claude = home.join(".claude/settings.json");
        write_json(
            &serde_json::json!({
                "mcpServers": {"keep": {"command": "unrelated"}},
                "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "keep"}]}]},
            }),
            &codex,
        );
        write_json(
            &serde_json::json!({
                "theme": "dark",
                "hooks": {"Notification": [{"hooks": [{"type": "command", "command": "keep"}]}]},
            }),
            &claude,
        );
        let installer = HostInstaller::new(home.clone(), DebriefPaths::for_home(&home).executable_url, None);

        let first = installer.install(&all_hosts()).unwrap();
        let second = installer.install(&all_hosts()).unwrap();

        assert!(first.codex_review_required);
        assert!(second.codex_review_required);
        assert!(Path::new(&format!("{}.debrief-backup", codex.display())).exists());
        assert!(Path::new(&format!("{}.debrief-backup", claude.display())).exists());

        let codex_json = json_at(&codex);
        let claude_json = json_at(&claude);
        assert!(codex_json["mcpServers"]["keep"].is_object());
        assert!(codex_json["mcpServers"].get("debrief").is_none());
        let codex_toml = fs::read_to_string(&codex_config).unwrap();
        assert!(codex_toml.contains("[mcp_servers.debrief]"));
        assert!(codex_toml.contains("# BEGIN debrief-mcp"));
        // Claude Code는 ~/.claude.json에서 사용자 MCP를 읽는다 — settings.json엔 들어가지 않는다.
        assert!(claude_json["mcpServers"].get("debrief").is_none());
        let claude_mcp = json_at(&home.join(".claude.json"));
        assert!(claude_mcp["mcpServers"]["debrief"].is_object());
        assert_eq!(claude_json["theme"], "dark");

        for (root, unrelated) in [(&codex_json, "PreToolUse"), (&claude_json, "Notification")] {
            let hooks = &root["hooks"];
            assert!(hooks[unrelated].is_array());
            for event in EmbeddedTemplates::HOOK_EVENTS {
                assert_eq!(hooks[event.as_str()].as_array().unwrap().len(), 1);
            }
            assert!(hooks["Stop"].is_array());
            assert!(hooks["PermissionRequest"].is_array());
            assert!(hooks.get("SubagentStop").is_none());
        }

        for source in [HostSource::Codex, HostSource::Claude] {
            let base = if source == HostSource::Codex { home.join(".agents/skills") } else { home.join(".claude/skills") };
            for name in EmbeddedTemplates::SKILL_NAMES {
                assert!(base.join(format!("debrief-{name}/SKILL.md")).exists());
            }
            let speak = fs::read_to_string(base.join("debrief-speak/SKILL.md")).unwrap();
            assert!(speak.contains("speak"));
            assert!(speak.contains("mcp__debrief__speak") || speak.contains("debrief__speak"));
        }
        let grok_skills_root = home.join(".grok/skills");
        for name in EmbeddedTemplates::SKILL_NAMES {
            assert!(grok_skills_root.join(format!("debrief-{name}/SKILL.md")).exists());
        }
        let grok_speak = fs::read_to_string(grok_skills_root.join("debrief-speak/SKILL.md")).unwrap();
        assert!(grok_speak.contains("debrief__speak"));
        assert!(grok_speak.contains("use_tool") || grok_speak.contains("search_tool"));
        let grok_install = fs::read_to_string(grok_skills_root.join("debrief-install/SKILL.md")).unwrap();
        assert!(grok_install.contains("debrief__install"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_merges_mcp_and_start_hooks_only() {
        let home = temporary_home();
        let codex = home.join(".codex/hooks.json");
        let codex_config = home.join(".codex/config.toml");
        write_json(
            &serde_json::json!({
                "mcpServers": {"keep": {"command": "unrelated"}},
                "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "keep"}]}]},
            }),
            &codex,
        );
        fs::create_dir_all(codex_config.parent().unwrap()).unwrap();
        fs::write(&codex_config, "[mcp_servers.other]\ncommand = \"/bin/echo\"\nenabled = true").unwrap();
        let grok_config = home.join(".grok/config.toml");
        fs::create_dir_all(grok_config.parent().unwrap()).unwrap();
        fs::write(&grok_config, "[mcp_servers.other]\ncommand = \"/bin/echo\"\nenabled = true").unwrap();

        let installer = HostInstaller::new(home.clone(), PathBuf::from("/tmp/debrief-bin"), None);
        installer.install(&all_hosts()).unwrap();

        let codex_json = json_at(&codex);
        let mcp_servers = &codex_json["mcpServers"];
        assert!(mcp_servers["keep"].is_object());
        assert!(mcp_servers.get("debrief").is_none());
        let hooks = &codex_json["hooks"];
        assert!(hooks["SessionStart"].is_array());
        assert!(hooks["UserPromptSubmit"].is_array());
        assert!(hooks["SubagentStart"].is_array());
        assert!(hooks["Stop"].is_array());
        assert!(hooks["PermissionRequest"].is_array());
        assert!(hooks.get("SubagentStop").is_none());
        assert!(hooks["PreToolUse"].is_array());

        let codex_toml = fs::read_to_string(&codex_config).unwrap();
        assert!(codex_toml.contains("[mcp_servers.other]"));
        assert!(codex_toml.contains("[mcp_servers.debrief]"));
        assert!(codex_toml.contains("# BEGIN debrief-mcp"));
        assert!(codex_toml.contains("# END debrief-mcp"));
        assert!(codex_toml.contains("/tmp/debrief-bin"));

        let toml = fs::read_to_string(&grok_config).unwrap();
        assert!(toml.contains("[mcp_servers.other]"));
        assert!(toml.contains("[mcp_servers.debrief]"));
        assert!(toml.contains("# BEGIN debrief-mcp"));
        assert!(toml.contains("# END debrief-mcp"));
        for name in EmbeddedTemplates::SKILL_NAMES {
            assert!(home.join(format!(".grok/skills/debrief-{name}/SKILL.md")).exists());
        }

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn uninstall_removes_mcp_preserves_others() {
        let home = temporary_home();
        let codex = home.join(".codex/hooks.json");
        let codex_config = home.join(".codex/config.toml");
        write_json(
            &serde_json::json!({
                "mcpServers": {"keep": {"command": "unrelated"}},
                "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "keep"}]}]},
            }),
            &codex,
        );
        fs::create_dir_all(codex_config.parent().unwrap()).unwrap();
        fs::write(&codex_config, "[mcp_servers.other]\ncommand = \"/bin/echo\"\nenabled = true").unwrap();
        let grok_config = home.join(".grok/config.toml");
        fs::create_dir_all(grok_config.parent().unwrap()).unwrap();
        fs::write(&grok_config, "[mcp_servers.other]\ncommand = \"/bin/echo\"\nenabled = true").unwrap();

        let installer = HostInstaller::new(home.clone(), PathBuf::from("/tmp/debrief-bin"), None);
        installer.install(&all_hosts()).unwrap();
        installer.uninstall(&all_hosts()).unwrap();

        let codex_json = json_at(&codex);
        let mcp_servers = &codex_json["mcpServers"];
        assert!(mcp_servers["keep"].is_object());
        assert!(mcp_servers.get("debrief").is_none());
        let hooks = &codex_json["hooks"];
        assert!(hooks["PreToolUse"].is_array());
        for event in EmbeddedTemplates::HOOK_EVENTS {
            assert!(hooks.get(event.as_str()).is_none());
        }

        let codex_toml = fs::read_to_string(&codex_config).unwrap();
        assert!(codex_toml.contains("[mcp_servers.other]"));
        assert!(!codex_toml.contains("[mcp_servers.debrief]"));
        assert!(!codex_toml.contains("# BEGIN debrief-mcp"));

        let toml = fs::read_to_string(&grok_config).unwrap();
        assert!(toml.contains("[mcp_servers.other]"));
        assert!(!toml.contains("[mcp_servers.debrief]"));
        assert!(!toml.contains("# BEGIN debrief-mcp"));
        for name in EmbeddedTemplates::SKILL_NAMES {
            assert!(!home.join(format!(".grok/skills/debrief-{name}/SKILL.md")).exists());
        }

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn claude_mcp_lives_in_claude_json_and_migrates_legacy_settings_entry() {
        let home = temporary_home();
        let executable = PathBuf::from("/tmp/debrief-bin");
        let settings = home.join(".claude/settings.json");
        let claude_json = home.join(".claude.json");
        let installer = HostInstaller::new(home.clone(), executable.clone(), None);

        // 예전 버전이 settings.json에 남긴 등록 (manifest에 소유로 기록됨).
        let (command, args) = EmbeddedTemplates::mcp_registration(&executable);
        let registration = serde_json::json!({"command": command, "args": args});
        write_json(&serde_json::json!({"mcpServers": {"debrief": registration.clone()}}), &settings);
        InstallManifest {
            hooks: Vec::new(),
            files: vec![OwnedInstalledFile {
                host: HostSource::Claude,
                path: HostInstaller::mcp_ownership_path(HostSource::Claude),
                sha256: InstallerDigest::json(&registration).unwrap(),
            }],
            runtime_files: Vec::<OwnedRuntimeFile>::new(),
        }
        .save(&DebriefPaths::for_home(&home).install_manifest_url)
        .unwrap();
        write_json(&serde_json::json!({"numStartups": 7, "mcpServers": {"keep": {"command": "unrelated"}}}), &claude_json);

        installer.install(&[HostSource::Claude].into_iter().collect()).unwrap();

        let mcp = json_at(&claude_json)["mcpServers"].clone();
        assert!(mcp["keep"].is_object());
        assert!(mcp["debrief"].is_object());
        assert_eq!(json_at(&claude_json)["numStartups"], 7);
        assert!(json_at(&settings)["mcpServers"].get("debrief").is_none());

        installer.uninstall(&[HostSource::Claude].into_iter().collect()).unwrap();

        let after = json_at(&claude_json)["mcpServers"].clone();
        assert!(after["keep"].is_object());
        assert!(after.get("debrief").is_none());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn uninstall_removes_only_unchanged_owned_content() {
        let home = temporary_home();
        let installer = HostInstaller::new(home.clone(), DebriefPaths::for_home(&home).executable_url, None);
        installer.install(&all_hosts()).unwrap();
        let modified = home.join(".agents/skills/debrief-setup/SKILL.md");
        fs::write(&modified, "user edit").unwrap();

        let result = installer.uninstall(&all_hosts()).unwrap();

        assert!(modified.exists());
        assert_eq!(result.preserved_modified_files, vec![modified.to_string_lossy().to_string()]);
        for settings in [home.join(".codex/hooks.json"), home.join(".claude/settings.json")] {
            let hooks = json_at(&settings)["hooks"].clone();
            for event in EmbeddedTemplates::HOOK_EVENTS {
                assert!(hooks.get(event.as_str()).is_none());
            }
        }
        let codex_toml = fs::read_to_string(home.join(".codex/config.toml")).unwrap();
        assert!(!codex_toml.contains("[mcp_servers.debrief]"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn malformed_settings_are_refused_without_backup_or_replacement() {
        let home = temporary_home();
        let settings = home.join(".codex/hooks.json");
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let original = b"[]".to_vec();
        fs::write(&settings, &original).unwrap();

        let installer = HostInstaller::new(home.clone(), DebriefPaths::for_home(&home).executable_url, None);
        let result = installer.install(&[HostSource::Codex].into_iter().collect());

        assert_eq!(result, Err(HostInstallerError::SettingsRootMustBeObject));
        assert_eq!(fs::read(&settings).unwrap(), original);
        assert!(!Path::new(&format!("{}.debrief-backup", settings.display())).exists());

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_removes_retired_owned_subagent_stop_hook_and_keeps_stop_single() {
        let home = temporary_home();
        let executable = PathBuf::from("/tmp/debrief-retired-hooks");
        let codex = home.join(".codex/hooks.json");
        let entry = EmbeddedTemplates::hook_entry(&executable, HostSource::Codex);
        let entry_json = HostInstaller::hook_entry_json(&entry);
        let digest = InstallerDigest::json(&entry_json).unwrap();
        write_json(&serde_json::json!({"hooks": {"Stop": [entry_json.clone()], "SubagentStop": [entry_json]}}), &codex);
        InstallManifest {
            hooks: vec![
                OwnedHook { host: HostSource::Codex, event: HookEventName::Stop, sha256: digest.clone() },
                OwnedHook { host: HostSource::Codex, event: HookEventName::SubagentStop, sha256: digest },
            ],
            files: Vec::new(),
            runtime_files: Vec::<OwnedRuntimeFile>::new(),
        }
        .save(&DebriefPaths::for_home(&home).install_manifest_url)
        .unwrap();

        HostInstaller::new(home.clone(), executable, None).install(&[HostSource::Codex].into_iter().collect()).unwrap();

        let hooks = json_at(&codex)["hooks"].clone();
        assert!(hooks.get("SubagentStop").is_none());
        let keys: HashSet<_> = hooks.as_object().unwrap().keys().cloned().collect();
        let expected: HashSet<_> = EmbeddedTemplates::HOOK_EVENTS.iter().map(|e| e.as_str().to_string()).collect();
        assert_eq!(keys, expected);
        for event in EmbeddedTemplates::HOOK_EVENTS {
            assert_eq!(hooks[event.as_str()].as_array().unwrap().len(), 1);
        }

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_strips_legacy_owned_json_mcp_from_codex_hooks() {
        let home = temporary_home();
        let executable = PathBuf::from("/tmp/debrief-bin");
        let codex = home.join(".codex/hooks.json");
        let registration = HostInstaller::mcp_registration_json(&executable);
        let digest = InstallerDigest::json(&registration).unwrap();
        write_json(
            &serde_json::json!({"mcpServers": {"keep": {"command": "unrelated"}, "debrief": registration}}),
            &codex,
        );
        InstallManifest {
            hooks: Vec::new(),
            files: vec![OwnedInstalledFile {
                host: HostSource::Codex,
                path: HostInstaller::mcp_ownership_path(HostSource::Codex),
                sha256: digest,
            }],
            runtime_files: Vec::<OwnedRuntimeFile>::new(),
        }
        .save(&DebriefPaths::for_home(&home).install_manifest_url)
        .unwrap();

        HostInstaller::new(home.clone(), executable, None).install(&[HostSource::Codex].into_iter().collect()).unwrap();

        let mcp_servers = json_at(&codex)["mcpServers"].clone();
        assert!(mcp_servers["keep"].is_object());
        assert!(mcp_servers.get("debrief").is_none());
        let toml = fs::read_to_string(home.join(".codex/config.toml")).unwrap();
        assert!(toml.contains("[mcp_servers.debrief]"));
        assert!(toml.contains("# BEGIN debrief-mcp"));

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_preserves_foreign_toml_mcp_on_codex() {
        let home = temporary_home();
        let codex_config = home.join(".codex/config.toml");
        fs::create_dir_all(codex_config.parent().unwrap()).unwrap();
        fs::write(&codex_config, "[mcp_servers.debrief]\ncommand = \"/usr/local/bin/other-debrief\"\nenabled = false").unwrap();

        let result = HostInstaller::new(home.clone(), PathBuf::from("/tmp/debrief-bin"), None)
            .install(&[HostSource::Codex].into_iter().collect())
            .unwrap();

        let toml = fs::read_to_string(&codex_config).unwrap();
        assert!(toml.contains("command = \"/usr/local/bin/other-debrief\""));
        assert!(toml.contains("enabled = false"));
        assert!(!toml.contains("# BEGIN debrief-mcp"));
        assert!(
            result.preserved_modified_files.contains(&codex_config.to_string_lossy().to_string())
                || result.preserved_modified_files.contains(&HostInstaller::mcp_ownership_path(HostSource::Codex))
        );

        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn install_does_not_clobber_unmanaged_grok_debrief_table() {
        let home = temporary_home();
        let grok_config = home.join(".grok/config.toml");
        fs::create_dir_all(grok_config.parent().unwrap()).unwrap();
        fs::write(&grok_config, "[mcp_servers.debrief]\ncommand = \"/usr/local/bin/foreign\"\nenabled = false").unwrap();

        let result = HostInstaller::new(home.clone(), PathBuf::from("/tmp/debrief-bin"), None)
            .install(&[HostSource::Grok].into_iter().collect())
            .unwrap();

        let toml = fs::read_to_string(&grok_config).unwrap();
        assert!(toml.contains("command = \"/usr/local/bin/foreign\""));
        assert!(toml.contains("enabled = false"));
        assert!(!toml.contains("# BEGIN debrief-mcp"));
        assert!(result.preserved_modified_files.contains(&grok_config.to_string_lossy().to_string()));
        for name in EmbeddedTemplates::SKILL_NAMES {
            assert!(home.join(format!(".grok/skills/debrief-{name}/SKILL.md")).exists());
        }

        fs::remove_dir_all(&home).ok();
    }
}
