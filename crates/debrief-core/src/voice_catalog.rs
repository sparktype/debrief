// 에이전트 유형 → 역할 보이스 매핑과 호스트별 MCP speak 계약 텍스트 생성
use crate::hook_event::{HookEvent, HookEventName, HostSource};
use crate::speech_request::SpeechPriority;
use std::collections::HashMap;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq)]
pub struct VoiceAssignment {
    pub category: String,
    pub voice: String,
    pub name: String,
    pub baseline_speed: f64,
}

impl VoiceAssignment {
    fn new(category: &str, voice: &str, name: &str, baseline_speed: f64) -> Self {
        VoiceAssignment {
            category: category.to_string(),
            voice: voice.to_string(),
            name: name.to_string(),
            baseline_speed,
        }
    }
}

pub struct VoiceCatalog;

/// `decide`로 미등록 agent_type을 분류할 때 제시하는 9개 역할 옵션 (`"default"` 제외).
const ROLE_CATEGORIES: [&str; 9] =
    ["reviewer", "planner", "builder", "tester", "explorer", "optimizer", "guardian", "ops", "specialist"];

static ALLOWED_VOICE_IDS: LazyLock<std::collections::HashSet<String>> = LazyLock::new(|| {
    [
        "F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
});

static ASSIGNMENTS: LazyLock<HashMap<&'static str, VoiceAssignment>> = LazyLock::new(|| {
    let mut map = HashMap::new();
    map.insert("reviewer", VoiceAssignment::new("reviewer", "M2", "빌", 0.92));
    map.insert("planner", VoiceAssignment::new("planner", "M1", "스티브", 1.10));
    map.insert("builder", VoiceAssignment::new("builder", "M4", "리누스", 0.95));
    map.insert("tester", VoiceAssignment::new("tester", "F2", "마리", 1.10));
    map.insert("explorer", VoiceAssignment::new("explorer", "F3", "제인", 1.00));
    map.insert("optimizer", VoiceAssignment::new("optimizer", "M3", "일론", 1.00));
    map.insert("guardian", VoiceAssignment::new("guardian", "M5", "팀", 0.88));
    map.insert("ops", VoiceAssignment::new("ops", "F4", "셰릴", 1.05));
    map.insert("specialist", VoiceAssignment::new("specialist", "F5", "리사", 0.88));
    map.insert("default", VoiceAssignment::new("default", "F1", "연아", 0.93));
    map
});

static AGENT_CATEGORIES: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| {
    let legacy: &[(&str, &[&str])] = &[
        (
            "reviewer",
            &[
                "feature-reviewer", "code-reviewer", "python-reviewer", "security-reviewer",
                "typescript-reviewer", "rust-reviewer", "go-reviewer", "kotlin-reviewer",
                "swift-reviewer", "cpp-reviewer", "java-reviewer", "csharp-reviewer",
                "flutter-reviewer", "fastapi-reviewer", "database-reviewer", "mle-reviewer",
                "pr-test-analyzer", "code-simplifier",
            ],
        ),
        (
            "planner",
            &[
                "feature-architect", "planner", "architect", "code-architect", "a11y-architect",
                "plan", "feature-dev", "gan-planner", "Plan",
            ],
        ),
        (
            "builder",
            &[
                "feature-builder", "build-error-resolver", "dart-build-resolver",
                "rust-build-resolver", "go-build-resolver", "kotlin-build-resolver",
                "swift-build-resolver", "cpp-build-resolver", "java-build-resolver",
                "pytorch-build-resolver", "gan-generator", "multi-execute", "doc-updater",
                "refactor-cleaner",
            ],
        ),
        ("tester", &["feature-tester", "tdd-guide", "e2e-runner", "gan-evaluator"]),
        (
            "explorer",
            &[
                "Explore", "code-explorer", "general-purpose", "gitnexus-exploring",
                "claude-code-guide", "Task",
            ],
        ),
        ("optimizer", &["performance-optimizer", "harness-optimizer", "type-design-analyzer"]),
        ("guardian", &["silent-failure-hunter", "comment-analyzer", "conversation-analyzer"]),
        (
            "ops",
            &[
                "loop-operator", "network-troubleshooter", "network-config-reviewer",
                "opensource-forker", "opensource-packager", "opensource-sanitizer", "hookify",
                "statusline-setup",
            ],
        ),
        ("specialist", &["healthcare-reviewer", "seo-specialist", "chief-of-staff", "claude"]),
    ];
    let aliases: &[(&str, &[&str])] = &[
        ("reviewer", &["verifier", "critic"]),
        ("builder", &["executor"]),
        ("tester", &["test-engineer"]),
        ("explorer", &["explore", "researcher"]),
        ("guardian", &["debugger"]),
        ("specialist", &["dependency-expert"]),
    ];

    let mut result: HashMap<&'static str, &'static str> = HashMap::new();
    for category in ASSIGNMENTS.keys().filter(|c| **c != "default") {
        result.insert(category, category);
    }
    for source in [legacy, aliases] {
        for (category, agent_types) in source {
            for agent_type in *agent_types {
                result.insert(agent_type, category);
            }
        }
    }
    result
});

impl VoiceCatalog {
    pub fn allowed_voice_ids() -> &'static std::collections::HashSet<String> {
        &ALLOWED_VOICE_IDS
    }

    pub fn assignment(agent_type: Option<&str>) -> VoiceAssignment {
        let Some(agent_type) = agent_type else {
            return ASSIGNMENTS["default"].clone();
        };
        let lowercase = agent_type.to_lowercase();
        let category = AGENT_CATEGORIES
            .get(agent_type)
            .or_else(|| AGENT_CATEGORIES.get(lowercase.as_str()))
            .copied()
            .unwrap_or("default");
        ASSIGNMENTS.get(category).cloned().unwrap_or_else(|| ASSIGNMENTS["default"].clone())
    }

    /// `assignment`와 동일하지만, 정적 매핑에 없는 agent_type은 `decide`로 9개 역할 중 하나를
    /// 분류해본 뒤에 폴백한다. `decide`가 불가하거나 유효하지 않은 카테고리를 돌려주면 기존처럼
    /// `"default"`로 떨어진다 — 정적 매핑에 있는 agent_type은 `decide`를 호출하지 않는다.
    pub fn assignment_with_decide(agent_type: Option<&str>, decide: &dyn crate::decide_client::DecideJudge) -> VoiceAssignment {
        let Some(agent_type) = agent_type else {
            return ASSIGNMENTS["default"].clone();
        };
        let lowercase = agent_type.to_lowercase();
        if let Some(category) = AGENT_CATEGORIES.get(agent_type).or_else(|| AGENT_CATEGORIES.get(lowercase.as_str())) {
            return ASSIGNMENTS.get(*category).cloned().unwrap_or_else(|| ASSIGNMENTS["default"].clone());
        }

        let classified = decide
            .choice(
                agent_type,
                "이 서브에이전트 이름을 아래 9개 역할 카테고리 중 가장 적합한 하나로 분류한다.",
                &ROLE_CATEGORIES,
            )
            .filter(|category| ROLE_CATEGORIES.contains(&category.as_str()));

        match classified {
            Some(category) => ASSIGNMENTS.get(category.as_str()).cloned().unwrap_or_else(|| ASSIGNMENTS["default"].clone()),
            None => ASSIGNMENTS["default"].clone(),
        }
    }

    pub fn persona_for_voice(voice: &str) -> VoiceAssignment {
        ASSIGNMENTS
            .values()
            .find(|assignment| assignment.voice == voice)
            .cloned()
            .unwrap_or_else(|| ASSIGNMENTS["default"].clone())
    }

    pub fn context(
        event: &HookEvent,
        source: HostSource,
        session_voice: Option<&str>,
        decide: &dyn crate::decide_client::DecideJudge,
    ) -> String {
        let assignment = Self::assignment_with_decide(event.agent_type.as_deref(), decide);
        let tool = Self::tool_reference(source);
        let priority = Self::recommended_priority(event.name);
        let companion = Self::persona_for_voice(session_voice.unwrap_or("F1"));

        match event.name {
            HookEventName::UserPromptSubmit => format!(
                "debrief: once at turn end, {tool}, lane=companion, voice {} ({}), \
session={}. Two short sentences in the user's language: \
what changed, then the one next action or wait. After code work, that action is what to verify to keep ownership. \
Silence only if nothing new. No file lists or checklists. No HTML/JSON in the body.",
                companion.voice, companion.name, event.session_id
            ),
            HookEventName::SubagentStart => format!(
                "Subagent: do not brief the user. The main agent speaks what changed and the next action. \
Speak once when your work is done: use {tool} with priority=subagent, lane=work, voice {} ({}): one fact only. \
focus/quiet/night suppress subagent. No HTML/JSON speech in the body.",
                assignment.voice, assignment.name
            ),
            HookEventName::SessionStart | HookEventName::Stop | HookEventName::SubagentStop => format!(
                "debrief turn briefing via {tool}. At the end of each user-visible turn, speak once: two short sentences \
in the user's language — what changed, then the one next action or wait. The agent writes the line. \
After writing, changing, or analyzing code, keep the user's code ownership and cut cognitive debt: \
the next action names what they must verify themselves (behavior change, deletion, security or data path, \
an assumption you made, how to check or undo). Skip it for trivial changes. \
Silence only if nothing new and no next action. Voice {} ({}), \
speed ~{}, volume ~0.85, lane=companion, session={}. \
The server keeps that companion voice for this session. \
emotion from neutral|warm|focused|concerned|relieved|tired (prosody only). \
Optional work lane for pure facts with role voice {} ({}), speed ~{}. \
Required args: text, voice, speed, volume. Optional: priority ({} default here), lane, emotion, session. \
No file lists or checklists. No HTML/JSON speech in the body. Mute, mode, and companion: debrief mute, debrief mode, debrief companion.",
                companion.voice,
                companion.name,
                Self::format(companion.baseline_speed),
                event.session_id,
                assignment.voice,
                assignment.name,
                Self::format(assignment.baseline_speed),
                priority.as_str()
            ),
        }
    }

    /// 이벤트 메타데이터 없이 호출하는 과거 호출자를 위한 하위 호환 헬퍼
    pub fn context_for_agent_type(agent_type: Option<&str>) -> String {
        let event = HookEvent {
            name: HookEventName::SessionStart,
            session_id: "compat".to_string(),
            turn_id: None,
            agent_type: agent_type.map(|s| s.to_string()),
            last_assistant_message: None,
        };
        Self::context(&event, HostSource::Claude, None, &crate::decide_client::NoopDecideClient)
    }

    fn tool_reference(source: HostSource) -> &'static str {
        match source {
            HostSource::Claude => "MCP tool `speak` on server `debrief` (may appear as `mcp__debrief__speak`)",
            HostSource::Codex => "MCP tool `speak` on server `debrief`",
            HostSource::Grok => "MCP tool `debrief__speak` (search_tool / use_tool; server `debrief`)",
        }
    }

    fn recommended_priority(event: HookEventName) -> SpeechPriority {
        match event {
            HookEventName::SubagentStart | HookEventName::SubagentStop => SpeechPriority::Subagent,
            HookEventName::SessionStart | HookEventName::UserPromptSubmit | HookEventName::Stop => {
                SpeechPriority::Main
            }
        }
    }

    fn format(value: f64) -> String {
        format!("{:.2}", value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_voice_routing() {
        let cases = [
            ("code-reviewer", "M2"),
            ("planner", "M1"),
            ("feature-builder", "M4"),
            ("e2e-runner", "F2"),
            ("explore", "F3"),
            ("code-simplifier", "M2"),
            ("security-reviewer", "M2"),
            ("performance-optimizer", "M3"),
            ("dependency-expert", "F5"),
            ("unknown-agent", "F1"),
            ("Plan", "M1"),
            ("Task", "F3"),
        ];
        for (agent_type, voice) in cases {
            assert_eq!(VoiceCatalog::assignment(Some(agent_type)).voice, voice, "{agent_type}");
        }
    }

    struct StubDecide {
        choice: Option<String>,
    }

    impl crate::decide_client::DecideJudge for StubDecide {
        fn noul(&self, _state: &str, _instructions: &str) -> Option<f64> {
            None
        }

        fn choice(&self, _state: &str, _instructions: &str, _options: &[&str]) -> Option<String> {
            self.choice.clone()
        }
    }

    #[test]
    fn unregistered_agent_type_uses_decide_classification_when_available() {
        let decide = StubDecide { choice: Some("planner".to_string()) };
        let assignment = VoiceCatalog::assignment_with_decide(Some("gan-planner-v2"), &decide);
        assert_eq!(assignment.category, "planner");
        assert_eq!(assignment.voice, "M1");
    }

    #[test]
    fn unregistered_agent_type_falls_back_to_default_when_decide_unavailable() {
        let decide = StubDecide { choice: None };
        let assignment = VoiceCatalog::assignment_with_decide(Some("gan-planner-v2"), &decide);
        assert_eq!(assignment.category, "default");
    }

    #[test]
    fn unregistered_agent_type_falls_back_to_default_on_invalid_decide_choice() {
        let decide = StubDecide { choice: Some("not-a-real-category".to_string()) };
        let assignment = VoiceCatalog::assignment_with_decide(Some("gan-planner-v2"), &decide);
        assert_eq!(assignment.category, "default");
    }

    #[test]
    fn registered_agent_type_does_not_consult_decide() {
        struct PanicIfCalled;
        impl crate::decide_client::DecideJudge for PanicIfCalled {
            fn noul(&self, _state: &str, _instructions: &str) -> Option<f64> {
                panic!("noul should not be called for a registered agent_type");
            }
            fn choice(&self, _state: &str, _instructions: &str, _options: &[&str]) -> Option<String> {
                panic!("choice should not be called for a registered agent_type");
            }
        }
        let assignment = VoiceCatalog::assignment_with_decide(Some("planner"), &PanicIfCalled);
        assert_eq!(assignment.voice, "M1");
    }

    #[test]
    fn roles_use_distinct_voices() {
        let roles = [
            "reviewer", "planner", "builder", "tester", "explorer",
            "optimizer", "guardian", "ops", "specialist", "default",
        ];
        let assignments: Vec<_> = roles.iter().map(|r| VoiceCatalog::assignment(Some(r))).collect();
        let voices: std::collections::HashSet<_> = assignments.iter().map(|a| a.voice.clone()).collect();
        let names: std::collections::HashSet<_> = assignments.iter().map(|a| a.name.clone()).collect();
        assert_eq!(voices.len(), roles.len());
        assert_eq!(names.len(), roles.len());
        let reviewer = VoiceCatalog::assignment(Some("reviewer"));
        assert_eq!(reviewer.voice, "M2");
        assert_eq!(reviewer.name, "빌");
        assert_eq!(reviewer.baseline_speed, 0.92);
        assert_eq!(VoiceCatalog::assignment(Some("optimizer")).voice, "M3");
        assert_eq!(VoiceCatalog::assignment(Some("optimizer")).name, "일론");
    }

    #[test]
    fn preserves_every_legacy_category_entry() {
        let expected: &[(&str, &[&str])] = &[
            (
                "reviewer",
                &[
                    "feature-reviewer", "code-reviewer", "python-reviewer", "security-reviewer",
                    "typescript-reviewer", "rust-reviewer", "go-reviewer", "kotlin-reviewer",
                    "swift-reviewer", "cpp-reviewer", "java-reviewer", "csharp-reviewer",
                    "flutter-reviewer", "fastapi-reviewer", "database-reviewer", "mle-reviewer",
                    "pr-test-analyzer", "code-simplifier",
                ],
            ),
            (
                "planner",
                &[
                    "feature-architect", "planner", "architect", "code-architect", "a11y-architect",
                    "plan", "feature-dev", "gan-planner", "Plan",
                ],
            ),
            (
                "builder",
                &[
                    "feature-builder", "build-error-resolver", "dart-build-resolver",
                    "rust-build-resolver", "go-build-resolver", "kotlin-build-resolver",
                    "swift-build-resolver", "cpp-build-resolver", "java-build-resolver",
                    "pytorch-build-resolver", "gan-generator", "multi-execute", "doc-updater",
                    "refactor-cleaner",
                ],
            ),
            ("tester", &["feature-tester", "tdd-guide", "e2e-runner", "gan-evaluator"]),
            (
                "explorer",
                &[
                    "Explore", "code-explorer", "general-purpose", "gitnexus-exploring",
                    "claude-code-guide", "Task",
                ],
            ),
            ("optimizer", &["performance-optimizer", "harness-optimizer", "type-design-analyzer"]),
            ("guardian", &["silent-failure-hunter", "comment-analyzer", "conversation-analyzer"]),
            (
                "ops",
                &[
                    "loop-operator", "network-troubleshooter", "network-config-reviewer",
                    "opensource-forker", "opensource-packager", "opensource-sanitizer", "hookify",
                    "statusline-setup",
                ],
            ),
            ("specialist", &["healthcare-reviewer", "seo-specialist", "chief-of-staff", "claude"]),
        ];

        let total: usize = expected.iter().map(|(_, types)| types.len()).sum();
        assert_eq!(total, 69);
        for (category, agent_types) in expected {
            for agent_type in *agent_types {
                assert_eq!(VoiceCatalog::assignment(Some(agent_type)).category, *category, "{agent_type}");
            }
        }
    }

    #[test]
    fn context_mentions_speak_tool_not_html_envelope() {
        let text = VoiceCatalog::context_for_agent_type(Some("planner"));
        assert!(text.contains("speak") || text.contains("mcp__debrief__speak"));
        assert!(text.contains("companion") || text.contains("F1"));
        assert!(text.contains("emotion") || text.contains("neutral"));
        assert!(!text.contains("chorus:speak"));
        assert!(!text.contains("<!--"));
        assert!(!text.to_lowercase().contains("debrief summarizes"));
    }

    #[test]
    fn claude_context_names_mcp_tool_alias() {
        let event = HookEvent {
            name: HookEventName::SessionStart,
            session_id: "s".to_string(),
            turn_id: None,
            agent_type: None,
            last_assistant_message: None,
        };
        let text = VoiceCatalog::context(&event, HostSource::Claude, None, &crate::decide_client::NoopDecideClient);
        assert!(text.contains("mcp__debrief__speak"));
        assert!(text.contains("F1"));
        assert!(text.to_lowercase().contains("silence") || text.contains("침묵") || text.contains("does not"));
    }

    #[test]
    fn subagent_context_requests_subagent_priority() {
        let event = HookEvent {
            name: HookEventName::SubagentStart,
            session_id: "s".to_string(),
            turn_id: Some("t".to_string()),
            agent_type: Some("planner".to_string()),
            last_assistant_message: None,
        };
        let text = VoiceCatalog::context(&event, HostSource::Claude, None, &crate::decide_client::NoopDecideClient);
        assert!(text.contains("subagent"));
        assert!(text.contains("M1"));
        assert!(text.contains("work") || text.contains("priority"));
        assert!(text.contains("do not brief"));
        assert!(text.contains("when your work is done"));
    }

    #[test]
    fn user_prompt_submit_context_is_compact() {
        let event = HookEvent {
            name: HookEventName::UserPromptSubmit,
            session_id: "s".to_string(),
            turn_id: None,
            agent_type: None,
            last_assistant_message: None,
        };
        let text = VoiceCatalog::context(&event, HostSource::Claude, None, &crate::decide_client::NoopDecideClient);
        assert!(text.chars().count() < 400);
        assert!(text.contains("companion") || text.contains("F1"));
        assert!(text.contains("Silence only"));
        assert!(text.contains("what changed"));
        assert!(text.contains("next action"));
        assert!(text.contains("ownership"));
    }

    #[test]
    fn session_start_briefs_what_changed_then_next_action() {
        let event = HookEvent {
            name: HookEventName::SessionStart,
            session_id: "s".to_string(),
            turn_id: None,
            agent_type: None,
            last_assistant_message: None,
        };
        let text = VoiceCatalog::context(&event, HostSource::Claude, None, &crate::decide_client::NoopDecideClient);
        assert!(text.contains("what changed"));
        assert!(text.contains("next action"));
        assert!(text.contains("agent writes"));
        assert!(text.contains("Silence only"));
        assert!(text.contains("debrief mute"));
        assert!(text.contains("ownership"));
        assert!(!text.to_lowercase().contains("menu bar"));
        assert!(!text.contains("menubar"));
        assert!(!text.to_lowercase().contains("debrief summarizes"));
    }
}
