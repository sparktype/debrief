use debrief_core::{
    CodexPaths, DebriefPaths, Diagnostics, HostInstaller, HostMcpState, HostSource,
};
use std::{fs, path::Path};

#[test]
fn custom_codex_profile_owns_only_its_settings_and_uses_shared_skills() {
    let home = tempfile::tempdir().unwrap();
    let profile = home.path().join("profiles/codex work");
    let paths = CodexPaths::from_root(profile.clone());
    let default = home.path().join(".codex");
    fs::create_dir_all(&default).unwrap();
    fs::create_dir_all(&profile).unwrap();
    fs::write(default.join("hooks.json"), "default-profile-hooks").unwrap();
    fs::write(default.join("config.toml"), "default-profile-config").unwrap();
    fs::write(
        &paths.config_url,
        "model = \"user-model\"\n[features]\nhooks = true\n",
    )
    .unwrap();
    fs::write(&paths.hooks_url, r#"{"custom":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}"#).unwrap();
    let executable = DebriefPaths::for_home(home.path()).executable_url;
    let installer = HostInstaller::new(home.path().to_owned(), executable, None)
        .with_codex_paths(paths.clone());
    let hosts = [HostSource::Codex].into_iter().collect();
    assert!(installer.install(&hosts).unwrap().codex_review_required);
    installer.install(&hosts).unwrap();
    assert!(home
        .path()
        .join(".agents/skills/debrief-speak/SKILL.md")
        .exists());
    assert!(!profile.join("skills").exists());
    let diagnostics =
        Diagnostics::with_checks(home.path(), |_| false, |_| false).with_codex_paths(paths.clone());
    assert_eq!(diagnostics.host_mcp_statuses()[0].state, HostMcpState::Ok);
    assert!(diagnostics
        .doctor()
        .iter()
        .any(|f| f.code == "hooks.codex.untrusted"));
    let json: serde_json::Value =
        serde_json::from_slice(&fs::read(&paths.hooks_url).unwrap()).unwrap();
    assert_eq!(json["hooks"]["SessionStart"].as_array().unwrap().len(), 2);
    installer.uninstall(&hosts).unwrap();
    let json: serde_json::Value =
        serde_json::from_slice(&fs::read(&paths.hooks_url).unwrap()).unwrap();
    assert_eq!(json["custom"], true);
    assert_eq!(json["hooks"]["SessionStart"].as_array().unwrap().len(), 1);
    assert_eq!(
        json["hooks"]["SessionStart"][0]["hooks"][0]["command"],
        "echo user-hook"
    );
    let config = fs::read_to_string(&paths.config_url).unwrap();
    assert!(config.contains("user-model"));
    assert!(!config.contains("mcp_servers.debrief"));
    assert_eq!(
        fs::read_to_string(default.join("hooks.json")).unwrap(),
        "default-profile-hooks"
    );
    assert_eq!(
        fs::read_to_string(default.join("config.toml")).unwrap(),
        "default-profile-config"
    );
}

#[test]
fn doctor_recovery_names_the_selected_profile() {
    let home = tempfile::tempdir().unwrap();
    let paths = CodexPaths::from_root(home.path().join("custom-codex"));
    fs::create_dir_all(paths.hooks_url.parent().unwrap()).unwrap();
    fs::write(&paths.hooks_url, "invalid-json").unwrap();
    let findings = Diagnostics::with_checks(home.path(), |_| false, |_| false)
        .with_codex_paths(paths.clone())
        .doctor();
    let recovery = findings
        .iter()
        .find(|f| f.code == "host.codex.invalid_json")
        .unwrap()
        .recovery
        .as_ref()
        .unwrap();
    assert!(recovery.contains(paths.hooks_url.to_str().unwrap()));
}

#[test]
fn plugin_skills_match_the_installer_and_have_no_duplicate_runtime_hooks() {
    let plugin = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins/debrief");
    for (name, content) in debrief_core::EmbeddedTemplates::skills(Path::new("debrief")) {
        assert_eq!(
            fs::read_to_string(plugin.join("skills").join(name).join("SKILL.md")).unwrap(),
            content,
            "regenerate plugin skill: {name}"
        );
    }
    assert!(!plugin.join("hooks/hooks.json").exists());
    assert!(!plugin.join("hooks/claude-hooks.json").exists());
    assert!(!plugin.join("skills/setup").exists());
}

#[test]
fn codex_environment_is_resolved_at_the_boundary_without_affecting_default_constructors() {
    const CHILD_HOME: &str = "DEBRIEF_TEST_CODEX_HOME";
    if let Some(home) = std::env::var_os(CHILD_HOME) {
        let home = Path::new(&home);
        let expected = std::env::var_os("CODEX_HOME")
            .filter(|value| !value.is_empty())
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        assert_eq!(
            CodexPaths::from_environment(home).config_url,
            expected.join("config.toml")
        );
        assert_eq!(
            CodexPaths::for_home(home).config_url,
            home.join(".codex/config.toml")
        );
        let fixture = tempfile::tempdir().unwrap();
        HostInstaller::new(fixture.path().to_owned(), "debrief".into(), None)
            .install(&[HostSource::Codex].into_iter().collect())
            .unwrap();
        assert!(fixture.path().join(".codex/config.toml").exists());
        return;
    }
    let home = tempfile::tempdir().unwrap();
    for value in [
        None,
        Some(std::ffi::OsString::new()),
        Some(home.path().join("profile with spaces").into_os_string()),
    ] {
        let mut child = std::process::Command::new(std::env::current_exe().unwrap());
        child.args(["--exact", "codex_environment_is_resolved_at_the_boundary_without_affecting_default_constructors"])
            .env(CHILD_HOME, home.path()).env_remove("CODEX_HOME");
        if let Some(value) = value {
            child.env("CODEX_HOME", value);
        }
        let result = child.output().unwrap();
        assert!(
            result.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
}

#[test]
fn selected_profile_trust_is_checked_without_writing_approval() {
    use debrief_core::{codex_trust::CodexTrust, EmbeddedTemplates};
    let home = tempfile::tempdir().unwrap();
    let paths = CodexPaths::from_root(home.path().join("profile"));
    let executable = DebriefPaths::for_home(home.path()).executable_url;
    let installer = HostInstaller::new(home.path().to_owned(), executable, None)
        .with_codex_paths(paths.clone());
    let hosts = [HostSource::Codex].into_iter().collect();
    assert!(installer.install(&hosts).unwrap().codex_review_required);
    let json: serde_json::Value =
        serde_json::from_slice(&fs::read(&paths.hooks_url).unwrap()).unwrap();
    let mut config = fs::read_to_string(&paths.config_url).unwrap();
    assert!(!config.contains("trusted_hash"));
    for event in EmbeddedTemplates::hook_events(HostSource::Codex) {
        let command = json["hooks"][event.as_str()][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        let name = CodexTrust::event_name(event);
        let hash = CodexTrust::identity_hash(
            name,
            command,
            CodexTrust::normalized_timeout(event, Some(5)),
            false,
        );
        config.push_str(&format!(
            "\n[hooks.state.\"{}:{name}:0:0\"]\ntrusted_hash = \"{hash}\"\nenabled = true\n",
            paths.hooks_url.canonicalize().unwrap().display()
        ));
    }
    fs::write(&paths.config_url, &config).unwrap();
    assert!(!installer.install(&hosts).unwrap().codex_review_required);
    let diagnostics =
        Diagnostics::with_checks(home.path(), |_| false, |_| false).with_codex_paths(paths.clone());
    assert!(!diagnostics
        .doctor()
        .iter()
        .any(|f| f.code == "hooks.codex.untrusted"));
    let after = fs::read_to_string(&paths.config_url).unwrap();
    for line in config.lines().filter(|line| line.contains("trusted_hash")) {
        assert!(after.contains(line));
    }
}

#[test]
fn runtime_install_and_uninstall_pass_the_selected_codex_profile() {
    use debrief_core::{
        InstalledModel, LaunchctlError, LaunchctlRunning, RuntimeInstaller, RuntimeModelInstalling,
    };
    struct Model(std::path::PathBuf);
    impl RuntimeModelInstalling for Model {
        fn install(&self, _: bool) -> Result<InstalledModel, debrief_core::ModelInstallerError> {
            Ok(InstalledModel {
                revision: "a".repeat(40),
                directory: self.0.clone(),
            })
        }
    }
    struct Launchctl;
    impl LaunchctlRunning for Launchctl {
        fn run(&self, _: &[String], _: bool) -> Result<(), LaunchctlError> {
            Ok(())
        }
    }
    let home = tempfile::tempdir().unwrap();
    let source = home.path().join("source-binary");
    fs::write(&source, "test executable").unwrap();
    let paths = CodexPaths::from_root(home.path().join("custom-profile"));
    let runtime = RuntimeInstaller::new(
        home.path().to_owned(),
        source,
        Model(home.path().join("model")),
        &Launchctl,
        501,
    )
    .with_codex_paths(paths.clone());
    let hosts = [HostSource::Codex].into_iter().collect();
    assert!(runtime.install(&hosts, true).unwrap().codex_review_required);
    assert!(paths.hooks_url.exists());
    assert!(fs::read_to_string(&paths.config_url)
        .unwrap()
        .contains("mcp_servers.debrief"));
    assert!(!home.path().join(".codex").exists());
    runtime.uninstall(&hosts).unwrap();
    assert!(!fs::read_to_string(&paths.config_url)
        .unwrap()
        .contains("mcp_servers.debrief"));
    let hooks: serde_json::Value =
        serde_json::from_slice(&fs::read(&paths.hooks_url).unwrap()).unwrap();
    assert!(hooks["hooks"].as_object().unwrap().is_empty());
    assert!(!home.path().join(".codex").exists());
}

#[test]
fn install_skill_examples_are_valid_arguments_for_the_named_host() {
    let skills = debrief_core::EmbeddedTemplates::skills(Path::new("debrief"));
    let install = &skills
        .iter()
        .find(|(name, _)| *name == "install")
        .unwrap()
        .1;
    for (label, host) in [("Codex", "codex"), ("Claude", "claude"), ("Grok", "grok")] {
        let line = install
            .lines()
            .find(|line| line.starts_with(&format!("- {label} only:")))
            .unwrap();
        let json = line.split('`').nth(1).unwrap();
        let args: serde_json::Value =
            serde_json::from_str(json).expect("skill example must be callable JSON");
        assert_eq!(args["hosts"], serde_json::json!([host]));
    }
}
