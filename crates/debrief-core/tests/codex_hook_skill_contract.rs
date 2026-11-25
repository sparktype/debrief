use debrief_core::{
    Control, DebriefConfiguration, DebriefMode, DebriefPaths, HookAdapter, HookCommandRunner,
    HookEngine, HostInstaller, HostSource, SessionStateStore,
};
use serde_json::{json, Value};
use std::fs;

const SESSION: &str = "01a212c5-5499-7910-82aa-c33c7a9f55de";

fn input(event: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"eventName": event, "conversationId": SESSION})).unwrap()
}

fn context(output: &[u8], event: &str) -> String {
    let value: Value = serde_json::from_slice(output).unwrap();
    assert_eq!(value["hookSpecificOutput"]["hookEventName"], event);
    value["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
fn codex_native_hooks_keep_the_fixed_voice_and_session_in_compact_prompt_output() {
    let home = tempfile::tempdir().unwrap();
    let paths = DebriefPaths::for_home(home.path());
    DebriefConfiguration {
        companion_voice: Some("M3".into()),
        ..Default::default()
    }
    .save(&paths.config_url)
    .unwrap();

    let start = context(
        &HookCommandRunner::run(&input("SessionStart"), HostSource::Codex, home.path()),
        "SessionStart",
    );
    let prompt = context(
        &HookCommandRunner::run(&input("UserPromptSubmit"), HostSource::Codex, home.path()),
        "UserPromptSubmit",
    );
    for text in [&start, &prompt] {
        assert!(text.contains("voice M3"), "{text}");
        assert!(text.contains(SESSION), "{text}");
        assert!(text.contains("speak") && text.contains("debrief"), "{text}");
        assert!(
            text.contains("what changed") && text.contains("next action"),
            "{text}"
        );
        assert!(text.contains("ownership"), "{text}");
    }
    // Includes a real UUID and the default mode guidance, not just a short test id.
    assert!(
        prompt.chars().count() < 360,
        "{}: {prompt}",
        prompt.chars().count()
    );
    assert!(prompt.len() < start.len());
    assert!(
        !paths.session_voices_url.exists(),
        "a fixed voice must not consume a rotation slot"
    );
}

#[test]
fn codex_prompt_modes_keep_guidance_and_session_cancellation() {
    for (mode, muted, english, guidance) in [
        (DebriefMode::Normal, false, false, "intent=decision"),
        (
            DebriefMode::Focus,
            false,
            false,
            "Mode focus: one sentence.",
        ),
        (DebriefMode::Quiet, false, false, "Mode quiet"),
        (
            DebriefMode::Night,
            false,
            false,
            "speak only with intent=decision",
        ),
        (
            DebriefMode::Normal,
            true,
            false,
            "debrief muted: do not call speak.",
        ),
        (DebriefMode::Normal, false, true, "English listening mode"),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let state = SessionStateStore::new(directory.path().join("state.json"));
        let configuration = DebriefConfiguration {
            mode,
            muted,
            english,
            ..Default::default()
        };
        let event = HookAdapter::decode(&input("UserPromptSubmit"), HostSource::Codex).unwrap();
        let result = HookEngine::new(None)
            .with_state(&state, configuration)
            .handle_at(&event, HostSource::Codex, 10);
        let text = context(&result.stdout, "UserPromptSubmit");
        assert!(
            text.contains(guidance),
            "{mode:?}, muted={muted}, english={english}: {text}"
        );
        assert_eq!(
            result.control,
            Some(Control::SkipSession(SESSION.to_owned()))
        );
        assert!(result.notice.is_none());
    }
}

#[test]
fn codex_subagent_keeps_its_role_voice_and_work_lane() {
    let payload = serde_json::to_vec(&json!({
        "eventName": "SubagentStart", "conversationId": SESSION, "agentType": "planner"
    }))
    .unwrap();
    let event = HookAdapter::decode(&payload, HostSource::Codex).unwrap();
    let result = HookEngine::new(None).handle_at(&event, HostSource::Codex, 10);
    let text = context(&result.stdout, "SubagentStart");
    for required in ["do not brief", "priority=subagent", "lane=work", "voice M1"] {
        assert!(text.contains(required), "missing {required}: {text}");
    }
    assert!(!text.contains("lane=companion"));
    assert!(result.control.is_none());
}

#[test]
fn codex_installed_speak_skill_is_discoverable_for_codex_and_keeps_output_boundaries() {
    let home = tempfile::tempdir().unwrap();
    let executable = DebriefPaths::for_home(home.path()).executable_url;
    HostInstaller::new(home.path().to_owned(), executable, None)
        .install(&[HostSource::Codex].into_iter().collect())
        .unwrap();
    let skill =
        fs::read_to_string(home.path().join(".agents/skills/debrief-speak/SKILL.md")).unwrap();
    let description = skill
        .lines()
        .find(|line| line.starts_with("description:"))
        .unwrap();
    assert!(
        description.contains("Codex"),
        "Codex must be discoverable in the skill catalog: {description}"
    );
    assert!(
        skill.contains("No HTML/JSON"),
        "speech metadata must stay out of the chat body"
    );
    assert!(skill.contains("intent") && skill.contains("muted") && skill.contains("ownership"));
}
