// Codex `hooks.state`의 trusted_hash와 설치한 훅이 같은지 본다.
//
// 해시 방식은 2026-10 Codex main의 NormalizedHookIdentity를 따른다.
// 키가 정렬된 JSON의 SHA-256이고 접두사는 `sha256:`이다. `async: false`는 빠지면 해시가 달라진다.
// SessionEnd·Interrupt의 timeout은 최대 3초로 잘린다. matcher가 없으면 필드 자체를 넣지 않는다.
// 상태 키는 `{hooks.json 절대경로}:{snake_event}:{group}:{handler}`이고, 빈 그룹도 인덱스를 차지한다.
// 지금 파일의 인덱스로만 찾는다. 다른 인덱스에 같은 해시가 있어도 이 핸들러를 신뢰한 것이 아니다.
use crate::hook_event::HookEventName;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexHookTrust {
    /// debrief Codex 훅이 없다.
    Silent,
    Trusted,
    /// 해시가 없거나 지금 핸들러와 다르다.
    Untrusted,
    /// 해시는 맞지만 `enabled = false`.
    Disabled,
    /// `[features] hooks = false`.
    FeatureDisabled,
    /// config.toml을 신뢰 판단에 쓸 수 없다. 신뢰했다고 말하지 않는다.
    ConfigUnreadable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HookState {
    trusted_hash: Option<String>,
    enabled: Option<bool>,
}

pub struct CodexTrust;

impl CodexTrust {
    pub fn event_name(event: HookEventName) -> &'static str {
        match event {
            HookEventName::SessionStart => "session_start",
            HookEventName::UserPromptSubmit => "user_prompt_submit",
            HookEventName::SubagentStart => "subagent_start",
            HookEventName::SubagentStop => "subagent_stop",
            HookEventName::Stop => "stop",
            HookEventName::PermissionRequest => "permission_request",
            HookEventName::StopFailure => "stop_failure",
            HookEventName::SessionEnd => "session_end",
            HookEventName::Notification => "notification",
            HookEventName::Elicitation => "elicitation",
            HookEventName::PermissionDenied => "permission_denied",
            HookEventName::TeammateIdle => "teammate_idle",
            HookEventName::TaskCompleted => "task_completed",
            HookEventName::PreCompact => "pre_compact",
            HookEventName::PostCompact => "post_compact",
            HookEventName::Interrupt => "interrupt",
            HookEventName::StopCancelled => "stop_cancelled",
        }
    }

    /// Codex가 신원에 넣는 timeout. SessionEnd·Interrupt만 1초 기본, 최대 3초.
    pub fn normalized_timeout(event: HookEventName, installed: Option<i64>) -> i64 {
        match event {
            HookEventName::SessionEnd | HookEventName::Interrupt => installed.unwrap_or(1).clamp(1, 3),
            _ => installed.unwrap_or(600).max(1),
        }
    }

    pub fn identity_hash(event_name: &str, command: &str, timeout: i64, is_async: bool) -> String {
        let identity = serde_json::json!({
            "event_name": event_name,
            "hooks": [{
                "async": is_async,
                "command": command,
                "timeout": timeout,
                "type": "command",
            }],
        });
        let raw = serde_json::to_vec(&identity).expect("hook identity always serializes");
        let mut hasher = Sha256::new();
        hasher.update(&raw);
        let digest = hasher.finalize();
        let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
        format!("sha256:{hex}")
    }

    pub fn review_required(home: &Path) -> bool {
        matches!(
            Self::assess(&home.join(".codex/hooks.json"), &home.join(".codex/config.toml")),
            CodexHookTrust::Untrusted
        )
    }

    pub fn assess(hooks_json: &Path, config_toml: &Path) -> CodexHookTrust {
        let Some(handlers) = debrief_handlers(hooks_json) else {
            return CodexHookTrust::Silent;
        };
        if handlers.is_empty() {
            return CodexHookTrust::Silent;
        }
        let parsed = match read_config(config_toml) {
            Ok(parsed) => parsed,
            Err(()) => return CodexHookTrust::ConfigUnreadable,
        };
        if parsed.feature_hooks == Some(false) {
            return CodexHookTrust::FeatureDisabled;
        }
        let hooks_key = canonical_path(hooks_json);
        let mut untrusted = false;
        let mut disabled = false;
        for handler in handlers {
            let Some(event) = HookEventName::from_str_value(&handler.event) else {
                untrusted = true;
                continue;
            };
            let timeout = Self::normalized_timeout(event, handler.timeout);
            let hash = Self::identity_hash(Self::event_name(event), &handler.command, timeout, handler.is_async);
            let key = format!("{}:{}:{}:{}", hooks_key.display(), Self::event_name(event), handler.group, handler.handler);
            match parsed.states.get(&key) {
                Some(state) if state.trusted_hash.as_deref() == Some(hash.as_str()) => {
                    if state.enabled == Some(false) {
                        disabled = true;
                    }
                }
                _ => untrusted = true,
            }
        }
        if untrusted {
            CodexHookTrust::Untrusted
        } else if disabled {
            CodexHookTrust::Disabled
        } else {
            CodexHookTrust::Trusted
        }
    }
}

struct OwnedHandler {
    event: String,
    group: usize,
    handler: usize,
    command: String,
    timeout: Option<i64>,
    is_async: bool,
}

struct ParsedConfig {
    feature_hooks: Option<bool>,
    states: HashMap<String, HookState>,
}

fn canonical_path(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn debrief_handlers(hooks_json: &Path) -> Option<Vec<OwnedHandler>> {
    if !hooks_json.exists() {
        return Some(Vec::new());
    }
    let data = fs::read(hooks_json).ok()?;
    let root: serde_json::Value = serde_json::from_slice(&data).ok()?;
    let hooks = root.get("hooks")?.as_object()?;
    let mut found = Vec::new();
    for (event, groups) in hooks {
        let Some(groups) = groups.as_array() else { continue };
        for (group_index, group) in groups.iter().enumerate() {
            let Some(handlers) = group.get("hooks").and_then(|value| value.as_array()) else { continue };
            for (handler_index, handler) in handlers.iter().enumerate() {
                let Some(command) = handler.get("command").and_then(|value| value.as_str()) else { continue };
                if !(command.contains("debrief") && command.contains("hook --source")) {
                    continue;
                }
                found.push(OwnedHandler {
                    event: event.clone(),
                    group: group_index,
                    handler: handler_index,
                    command: command.to_string(),
                    timeout: handler.get("timeout").and_then(|value| value.as_i64()),
                    is_async: handler.get("async").and_then(|value| value.as_bool()).unwrap_or(false),
                });
            }
        }
    }
    Some(found)
}

/// 파일이 없으면 빈 설정이다. 읽을 수 없거나 `hooks.state`·`features` 줄이 깨졌으면 오류.
fn read_config(path: &Path) -> Result<ParsedConfig, ()> {
    if !path.exists() {
        return Ok(ParsedConfig { feature_hooks: None, states: HashMap::new() });
    }
    let text = fs::read_to_string(path).map_err(|_| ())?;
    parse_config(&text)
}

fn parse_config(text: &str) -> Result<ParsedConfig, ()> {
    let mut section = String::new();
    let mut state_key: Option<String> = None;
    let mut feature_hooks = None;
    let mut states: HashMap<String, HookState> = HashMap::new();
    for raw in text.lines() {
        let line = strip_comment(raw);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            state_key = section.strip_prefix("hooks.state.").map(|key| unquote(key.trim()));
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            if state_key.is_some() || section == "features" {
                return Err(());
            }
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        if section == "features" && key == "hooks" {
            feature_hooks = Some(parse_bool(value)?);
        }
        if let Some(state_key) = &state_key {
            let entry = states.entry(state_key.clone()).or_insert_with(|| HookState { trusted_hash: None, enabled: None });
            if key == "trusted_hash" {
                entry.trusted_hash = Some(unquote(value));
            } else if key == "enabled" {
                entry.enabled = Some(parse_bool(value)?);
            }
        }
    }
    Ok(ParsedConfig { feature_hooks, states })
}

fn parse_bool(value: &str) -> Result<bool, ()> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(()),
    }
}

fn unquote(value: &str) -> String {
    let trimmed = value.trim();
    trimmed.strip_prefix('"').and_then(|rest| rest.strip_suffix('"')).unwrap_or(trimmed).to_string()
}

fn strip_comment(line: &str) -> String {
    let mut output = String::new();
    let mut quote: Option<char> = None;
    for character in line.chars() {
        if let Some(mark) = quote {
            output.push(character);
            if character == mark {
                quote = None;
            }
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
            output.push(character);
            continue;
        }
        if character == '#' {
            break;
        }
        output.push(character);
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMAND: &str = "'/Users/spark/.local/bin/debrief' hook --source codex";

    #[test]
    fn identity_hash_matches_codex_main_as_of_2026_10() {
        let hash = |event, timeout| CodexTrust::identity_hash(event, COMMAND, timeout, false);
        assert_eq!(hash("session_start", 5), "sha256:6c1d51b82764391842cd05978bb51091af3b2f0f52084b651f1d5c1902c2b8d5");
        assert_eq!(hash("permission_request", 5), "sha256:a30708c92e1ad10cdba11ef4c28a0bb028df6162e874a808739c8e20b38f0244");
        assert_eq!(hash("user_prompt_submit", 5), "sha256:50a5e2621efe7d6a8448b12ff0f13515b7ae6cdf55579a14270fee6ba3903705");
        assert_eq!(hash("stop", 5), "sha256:34f51482a7ae5e9f4614d37f2d02de78027c4abb955e636d137772878700f771");
        assert_eq!(hash("session_end", 3), "sha256:e3eadcd4b25f59ba85676546252392346a82b15c344fd1a8dfc9a78a5a78d004");
        assert_eq!(hash("interrupt", 3), "sha256:f69772cc68a3322fb399d0c3985407869897df1dcdde3a8b18439cc2cc8d6deb");
        assert_ne!(
            CodexTrust::identity_hash("user_prompt_submit", COMMAND, 5, false),
            CodexTrust::identity_hash("user_prompt_submit", COMMAND, 5, true),
            "async를 빼면 저장된 해시와 달라진다"
        );
    }

    #[test]
    fn session_end_and_interrupt_timeouts_clamp_to_three_seconds() {
        assert_eq!(CodexTrust::normalized_timeout(HookEventName::SessionEnd, Some(5)), 3);
        assert_eq!(CodexTrust::normalized_timeout(HookEventName::Interrupt, None), 1);
        assert_eq!(CodexTrust::normalized_timeout(HookEventName::Stop, Some(5)), 5);
        assert_eq!(CodexTrust::normalized_timeout(HookEventName::Stop, None), 600);
    }

    fn home() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let url = PathBuf::from("/tmp").join(format!("codex-trust-{}-{}", nanos, COUNTER.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir_all(url.join(".codex")).unwrap();
        url
    }

    fn write_hooks(home: &Path, groups_before: usize) -> PathBuf {
        let hooks = home.join(".codex/hooks.json");
        let handler = serde_json::json!({
            "hooks": [{ "type": "command", "command": COMMAND, "timeout": 5 }]
        });
        let mut groups = vec![serde_json::json!({}); groups_before];
        groups.push(handler);
        let mut events = serde_json::Map::new();
        events.insert("Stop".to_string(), serde_json::Value::Array(groups));
        fs::write(&hooks, serde_json::to_vec(&serde_json::json!({ "hooks": events })).unwrap()).unwrap();
        hooks
    }

    #[test]
    fn trust_uses_the_current_group_index_only() {
        let home = home();
        let hooks = write_hooks(&home, 2);
        let canonical = hooks.canonicalize().unwrap();
        let hash = CodexTrust::identity_hash("stop", COMMAND, 5, false);
        let config = home.join(".codex/config.toml");
        // 예전 인덱스 0에만 해시가 있다. 지금 핸들러는 그룹 2다.
        fs::write(&config, format!("[hooks.state.\"{}:stop:0:0\"]\ntrusted_hash = \"{hash}\"\nenabled = true\n", canonical.display())).unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &config), CodexHookTrust::Untrusted);

        fs::write(&config, format!("[hooks.state.\"{}:stop:2:0\"]\ntrusted_hash = \"{hash}\"\nenabled = true\n", canonical.display())).unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &config), CodexHookTrust::Trusted);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn disabled_and_feature_flag_are_not_reported_as_untrusted() {
        let home = home();
        let hooks = write_hooks(&home, 0);
        let canonical = hooks.canonicalize().unwrap();
        let hash = CodexTrust::identity_hash("stop", COMMAND, 5, false);
        let config = home.join(".codex/config.toml");
        fs::write(&config, format!("[hooks.state.\"{}:stop:0:0\"]\ntrusted_hash = \"{hash}\"\nenabled = false\n", canonical.display())).unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &config), CodexHookTrust::Disabled);

        fs::write(
            &config,
            format!("[features]\nhooks = false\n\n[hooks.state.\"{}:stop:0:0\"]\ntrusted_hash = \"{hash}\"\nenabled = true\n", canonical.display()),
        )
        .unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &config), CodexHookTrust::FeatureDisabled);

        fs::write(&config, "[features]\nhooks = maybe\n").unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &config), CodexHookTrust::ConfigUnreadable);
        assert!(!CodexTrust::review_required(&home), "읽지 못하면 신뢰 문장을 내걸지 않는다");
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn no_debrief_hook_stays_silent() {
        let home = home();
        let hooks = home.join(".codex/hooks.json");
        fs::write(&hooks, br#"{"hooks":{"Stop":[{"hooks":[{"command":"echo hi","timeout":5}]}]}}"#).unwrap();
        assert_eq!(CodexTrust::assess(&hooks, &home.join(".codex/config.toml")), CodexHookTrust::Silent);
        fs::remove_dir_all(&home).ok();
    }
}
