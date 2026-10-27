// 훅 이벤트를 호스트에 돌려줄 stdout(JSON)으로 변환한다. speak 계약은 MCP speak 도구가 맡고,
// 이 엔진은 에이전트가 말할 수 없는 두 순간(권한 요청, 말없이 끝난 긴 턴)에 한해
// 고정 문구 알림 요청(`HookResult.notice`)을 돌려준다. 전송은 호출자(러너)가 한다.
use crate::configuration::DebriefConfiguration;
use crate::hook_adapter::HookAdapter;
use crate::hook_event::{HookEvent, HookEventName, HostSource};
use crate::session_state::{now_seconds, project_label, SessionStateStore};
use crate::session_voice_rotation::SessionVoiceStore;
use crate::speech_emotion::SpeechEmotion;
use crate::speech_envelope::SpeechEnvelope;
use crate::speech_lane::SpeechLane;
use crate::speech_request::{SpeechPriority, SpeechRequest};
use crate::voice_catalog::VoiceCatalog;

pub struct HookResult {
    pub stdout: Vec<u8>,
    pub submitted: bool,
    pub delivery_error: Option<String>,
    /// 데몬에 바로 보낼 고정 문구 알림. 대부분의 이벤트에서는 `None`이다.
    pub notice: Option<SpeechRequest>,
    /// 데몬에 보낼 제어 명령. 새 프롬프트는 이 세션의 낡은 브리핑을 끊는다.
    pub control: Option<crate::daemon_control::Control>,
}

pub struct HookEngine<'a> {
    session_voices: Option<&'a SessionVoiceStore>,
    state: Option<&'a SessionStateStore>,
    configuration: DebriefConfiguration,
    dnd_raised: bool,
}

impl<'a> HookEngine<'a> {
    const NOTICE_SPEED: f64 = 0.93;
    const NOTICE_VOLUME: f64 = 0.85;

    pub fn new(session_voices: Option<&'a SessionVoiceStore>) -> Self {
        HookEngine { session_voices, state: None, configuration: DebriefConfiguration::default(), dnd_raised: false }
    }

    /// 방해금지 때문에 유효 모드가 올라갔는지 — 모드 지침에 `(dnd)`를 붙인다.
    pub fn with_dnd_raised(mut self, raised: bool) -> Self {
        self.dnd_raised = raised;
        self
    }

    /// 유효 모드별 행동 규칙 한 줄. 에이전트가 말투와 침묵을 스스로 맞추게 한다.
    pub fn mode_guidance(configuration: &DebriefConfiguration, dnd_raised: bool) -> String {
        use crate::configuration::DebriefMode;
        if configuration.muted {
            return "debrief muted: do not call speak.".to_string();
        }
        let decision = "Needs a user decision? pass intent=decision.";
        let mode = match configuration.mode {
            DebriefMode::Normal | DebriefMode::Verbose => return decision.to_string(),
            DebriefMode::Focus => "Mode focus: one sentence.".to_string(),
            DebriefMode::Quiet => {
                format!("Mode quiet{}: one short sentence, or silence.", if dnd_raised { " (dnd)" } else { "" })
            }
            DebriefMode::Night => "Mode night: speak only with intent=decision.".to_string(),
        };
        format!("{decision} {mode}")
    }

    /// 세션 상태(턴 시작 시각, 프로젝트 레이블)를 추적해 긴 턴 알림과 레이블을 켠다.
    pub fn with_state(mut self, state: &'a SessionStateStore, configuration: DebriefConfiguration) -> Self {
        self.state = Some(state);
        self.configuration = configuration;
        self
    }

    pub fn handle(&self, event: &HookEvent, source: HostSource) -> HookResult {
        self.handle_at(event, source, now_seconds())
    }

    pub fn handle_at(&self, event: &HookEvent, source: HostSource, now: u64) -> HookResult {
        let (notice, remind) = self.notice_for(event, now);
        if remind {
            return HookResult {
                stdout: Self::reminder_output(event, source),
                submitted: false,
                delivery_error: None,
                notice: None,
                control: None,
            };
        }
        match event.name {
            HookEventName::SessionStart | HookEventName::UserPromptSubmit | HookEventName::SubagentStart => {
                // 서브에이전트는 역할 보이스를 유지하고 세션 로테이션의 슬롯을 차지하지 않는다.
                let session_voice = if matches!(event.name, HookEventName::SubagentStart) {
                    None
                } else {
                    self.session_voices.and_then(|store| store.claim(&event.session_id).ok())
                };
                let context = VoiceCatalog::context_with_voices(
                    event,
                    source,
                    session_voice.as_deref(),
                    &self.configuration.category_voices,
                );
                let context = if matches!(event.name, HookEventName::SubagentStart) {
                    context
                } else {
                    format!("{context} {}", Self::mode_guidance(&self.configuration, self.dnd_raised))
                };
                let stdout = HookAdapter::context_output(&context, event, source);
                let control = matches!(event.name, HookEventName::UserPromptSubmit)
                    .then(|| crate::daemon_control::Control::SkipSession(event.session_id.clone()));
                HookResult { stdout, submitted: false, delivery_error: None, notice, control }
            }
            _ => {
                // 중단된 턴의 브리핑은 이미 낡았다(Codex Interrupt).
                let control = matches!(event.name, HookEventName::Interrupt)
                    .then(|| crate::daemon_control::Control::SkipSession(event.session_id.clone()));
                HookResult { stdout: HookAdapter::success_output(), submitted: false, delivery_error: None, notice, control }
            }
        }
    }

    const REMINDER: &'static str = "debrief: this turn ended without the spoken briefing. Call speak once now \
(what changed, then the next action), then stop. If there is truly nothing new, stop without speaking.";

    /// Claude는 오류 표시 없는 Stop 피드백(additionalContext), Codex는 `decision: block`으로 턴을 잇는다.
    fn reminder_output(event: &HookEvent, source: HostSource) -> Vec<u8> {
        match source {
            HostSource::Codex => serde_json::to_vec(&serde_json::json!({"decision": "block", "reason": Self::REMINDER}))
                .expect("reminder output always serializes"),
            _ => HookAdapter::context_output(Self::REMINDER, event, source),
        }
    }

    /// 침묵을 허용하는 모드(quiet·night·음소거)에서는 되돌리지 않는다. 되돌린 뒤의 Stop도 마찬가지다.
    fn reminder_applies(&self, event: &HookEvent) -> bool {
        use crate::configuration::DebriefMode;
        self.configuration.briefing_reminder
            && !self.configuration.muted
            && !event.stop_hook_active
            && matches!(self.configuration.mode, DebriefMode::Normal | DebriefMode::Verbose | DebriefMode::Focus)
    }

    /// 같은 종류 알림 사이에 두는 최소 간격(초). 잦을 수 있는 이벤트에만 둔다.
    fn cooldown_seconds(name: HookEventName) -> Option<u64> {
        match name {
            HookEventName::Notification => Some(300),
            HookEventName::PermissionDenied | HookEventName::TeammateIdle | HookEventName::TaskCompleted => Some(120),
            _ => None,
        }
    }

    fn failure_text(error_type: Option<&str>) -> &'static str {
        match error_type {
            Some("rate_limit" | "overloaded") => "사용 한도나 서버 과부하로 작업이 멈췄습니다.",
            Some("authentication_failed" | "oauth_org_not_allowed" | "account_on_hold" | "billing_error") => {
                "계정 문제로 작업이 멈췄습니다."
            }
            _ => "API 오류로 작업이 멈췄습니다.",
        }
    }

    /// 알림 종류별 효과음. 일반 브리핑·압축 시작·팀원 대기에는 없다.
    pub fn cue_for(name: HookEventName) -> Option<crate::earcon::Earcon> {
        use crate::earcon::Earcon;
        match name {
            HookEventName::PermissionRequest
            | HookEventName::Notification
            | HookEventName::Elicitation
            | HookEventName::PermissionDenied => Some(Earcon::Attention),
            HookEventName::StopFailure => Some(Earcon::Failure),
            HookEventName::Stop | HookEventName::TaskCompleted | HookEventName::PostCompact => Some(Earcon::Done),
            _ => None,
        }
    }

    /// 세션 상태를 갱신하고, 이 이벤트가 알림을 내야 하면 요청을 만든다.
    /// 두 번째 값이 참이면 알림 대신 Stop을 되돌려 브리핑을 요청한다(이때 턴은 닫지 않는다).
    fn notice_for(&self, event: &HookEvent, now: u64) -> (Option<SpeechRequest>, bool) {
        let remindable = self.reminder_applies(event);
        // 알림을 내는 이벤트인지 먼저 정한다(쿨다운은 실제로 말할 때만 소모한다).
        let wants_notice = match event.name {
            HookEventName::Notification => matches!(event.subtype.as_deref(), Some("idle_prompt" | "agent_needs_input")),
            HookEventName::TeammateIdle | HookEventName::TaskCompleted => self.configuration.team_notices,
            // 수동 `/compact`는 사용자가 직접 한 것이라 알리지 않는다.
            HookEventName::PreCompact | HookEventName::PostCompact => event.subtype.as_deref() == Some("auto"),
            HookEventName::PermissionRequest
            | HookEventName::Stop
            | HookEventName::StopFailure
            | HookEventName::Elicitation
            | HookEventName::PermissionDenied => true,
            _ => false,
        };
        let cooldown = Self::cooldown_seconds(event.name).filter(|_| wants_notice);

        let tracked = self.state.and_then(|state| {
            let project = event.cwd.as_deref().and_then(project_label);
            let threshold = self.configuration.long_turn_seconds;
            state
                .update(now, |states| {
                    if event.name == HookEventName::SessionEnd {
                        states.remove(&event.session_id);
                        return (None, None, false, false);
                    }
                    states.touch(&event.session_id, project, now);
                    let mut long_turn_elapsed = None;
                    let long_silent = |(elapsed, spoken): &(u64, bool)| !spoken && threshold > 0 && *elapsed >= threshold;
                    if event.name == HookEventName::Stop
                        && remindable
                        && states.peek_turn(&event.session_id, now).is_some_and(|turn| long_silent(&turn))
                    {
                        return (None, None, true, true);
                    }
                    match event.name {
                        HookEventName::UserPromptSubmit => states.begin_turn(&event.session_id, now),
                        HookEventName::Stop => {
                            long_turn_elapsed = states
                                .finish_turn(&event.session_id, now)
                                .filter(long_silent)
                                .map(|(elapsed, _)| elapsed);
                        }
                        // 실패로 끝난 턴은 이후 Stop의 완료 알림 대상에서 뺀다.
                        HookEventName::StopFailure => {
                            states.finish_turn(&event.session_id, now);
                        }
                        _ => {}
                    }
                    let allowed = cooldown
                        .map(|seconds| states.allow_notice(&event.session_id, event.name.as_str(), now, seconds))
                        .unwrap_or(true);
                    let label = self.configuration.session_label.then(|| states.label_for(&event.session_id, now));
                    (long_turn_elapsed, label.flatten(), allowed, false)
                })
                .ok()
        });
        // 상태 저장소를 쓸 수 없으면 쿨다운이 필요한 알림은 조용히 건너뛴다.
        let (long_turn_elapsed, label, allowed, remind) = tracked.unwrap_or((None, None, cooldown.is_none(), false));
        if remind {
            return (None, true);
        }
        if !wants_notice || !allowed {
            return (None, false);
        }

        let (body, emotion) = match event.name {
            HookEventName::PermissionRequest => ("권한 승인을 기다리고 있습니다.".to_string(), SpeechEmotion::Concerned),
            HookEventName::Stop => {
                let Some(elapsed) = long_turn_elapsed else { return (None, false) };
                let minutes = ((elapsed + 30) / 60).max(1);
                (format!("{minutes}분 걸린 작업이 끝났습니다."), SpeechEmotion::Neutral)
            }
            HookEventName::StopFailure => (Self::failure_text(event.subtype.as_deref()).to_string(), SpeechEmotion::Concerned),
            HookEventName::Notification => ("입력을 기다리고 있습니다.".to_string(), SpeechEmotion::Neutral),
            HookEventName::Elicitation => ("추가 입력이 필요합니다.".to_string(), SpeechEmotion::Concerned),
            HookEventName::PermissionDenied => {
                ("자동 모드가 도구 호출을 거부했습니다.".to_string(), SpeechEmotion::Concerned)
            }
            HookEventName::TeammateIdle => ("팀원이 대기 중입니다.".to_string(), SpeechEmotion::Neutral),
            HookEventName::TaskCompleted => ("작업 항목이 하나 끝났습니다.".to_string(), SpeechEmotion::Neutral),
            HookEventName::PreCompact => ("컨텍스트를 정리하고 있습니다.".to_string(), SpeechEmotion::Neutral),
            // 압축이 끝나면 말 대신 완료음만 낸다.
            HookEventName::PostCompact => (String::new(), SpeechEmotion::Neutral),
            _ => return (None, false),
        };
        let text = match label {
            Some(label) if !body.is_empty() => format!("{label}. {body}"),
            _ => body,
        };
        let voice = self
            .session_voices
            .and_then(|store| store.claim(&event.session_id).ok())
            .unwrap_or_else(|| "F1".to_string());
        let notice = SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text, voice, speed: Self::NOTICE_SPEED, volume: Self::NOTICE_VOLUME },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Work,
            emotion,
            agent_type: None,
            decision: false,
            cue: Self::cue_for(event.name),
            replayed: false,
            session: None,
        };
        (Some(notice), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook_event::HookEventName;

    fn event(
        name: HookEventName,
        session_id: &str,
        turn_id: Option<&str>,
        agent_type: Option<&str>,
        last_assistant_message: Option<&str>,
    ) -> HookEvent {
        HookEvent {
            name,
            session_id: session_id.to_string(),
            turn_id: turn_id.map(|s| s.to_string()),
            agent_type: agent_type.map(|s| s.to_string()),
            last_assistant_message: last_assistant_message.map(|s| s.to_string()),
            cwd: None,
            subtype: None,
            stop_hook_active: false,
        }
    }

    #[test]
    fn prompt_submit_asks_to_skip_the_sessions_stale_briefing() {
        use crate::daemon_control::Control;
        let engine = HookEngine::new(None);
        let submit = engine.handle(&event(HookEventName::UserPromptSubmit, "alpha", Some("t"), None, None), HostSource::Claude);
        assert_eq!(submit.control, Some(Control::SkipSession("alpha".to_string())));
        let start = engine.handle(&event(HookEventName::SessionStart, "alpha", None, None, None), HostSource::Claude);
        assert_eq!(start.control, None);
    }

    #[test]
    fn codex_interrupt_cuts_the_sessions_briefing_silently() {
        use crate::daemon_control::Control;
        let result = HookEngine::new(None).handle(&event(HookEventName::Interrupt, "alpha", Some("t"), None, None), HostSource::Codex);
        assert_eq!(result.control, Some(Control::SkipSession("alpha".to_string())));
        assert!(result.notice.is_none());
        assert_eq!(result.stdout, b"{}");
    }

    #[test]
    fn subagent_context_uses_assigned_voice() {
        let event = event(HookEventName::SubagentStart, "s", Some("t"), Some("planner"), None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        let text = String::from_utf8(result.stdout).unwrap();
        assert!(text.contains("M1"));
        assert!(text.contains("subagent"));
        assert!(text.contains("mcp__debrief__speak") || text.contains("speak"));
        assert!(!result.submitted);
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn session_start_uses_host_agent_type_when_present() {
        let event = event(HookEventName::SessionStart, "s", None, Some("Explore"), None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        let text = String::from_utf8(result.stdout).unwrap();
        assert!(text.contains("F3"));
        assert!(text.contains("제인"));
        assert!(!result.submitted);
    }

    #[test]
    fn session_voices_rotate_and_subagents_do_not_take_a_slot() {
        let url = std::env::temp_dir().join(format!(
            "debrief-hook-voices-{}.json",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _cleanup = Cleanup(url.clone());

        let store = SessionVoiceStore::new(url);
        let engine = HookEngine::new(Some(&store));

        let text = |result: HookResult| String::from_utf8(result.stdout).unwrap();

        let first = engine.handle(&event(HookEventName::SessionStart, "alpha", None, None, None), HostSource::Claude);
        let second = engine.handle(&event(HookEventName::SessionStart, "beta", None, None, None), HostSource::Claude);
        let again =
            engine.handle(&event(HookEventName::UserPromptSubmit, "alpha", Some("t"), None, None), HostSource::Claude);
        let subagent = engine.handle(
            &event(HookEventName::SubagentStart, "child", None, Some("planner"), None),
            HostSource::Claude,
        );

        assert!(text(first).contains("F1 (연아)"));
        assert!(text(second).contains("F2 (마리)"));
        assert!(text(again).contains("F1 (연아)"));
        let subagent_text = text(subagent);
        assert!(subagent_text.contains("M1"));
        assert!(!subagent_text.contains("session="));
        assert_eq!(store.claim("gamma").unwrap(), "F3");
    }

    #[test]
    fn user_prompt_submit_defaults_to_main_voice_without_agent_type() {
        let event = event(HookEventName::UserPromptSubmit, "s", None, None, None);
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(String::from_utf8(result.stdout).unwrap().contains("F1"));
    }

    #[test]
    fn stop_does_not_submit_even_with_legacy_envelope() {
        let event = event(
            HookEventName::Stop,
            "s",
            None,
            None,
            Some("<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"F1\",\"speed\":0.93,\"volume\":0.85} -->"),
        );
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn subagent_stop_does_not_submit_even_with_legacy_envelope() {
        let event = event(
            HookEventName::SubagentStop,
            "s",
            Some("t"),
            Some("planner"),
            Some("<!-- chorus:speak {\"v\":1,\"text\":\"nope\",\"voice\":\"M1\",\"speed\":1.1,\"volume\":0.85} -->"),
        );
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
        assert!(result.delivery_error.is_none());
    }

    #[test]
    fn stop_without_message_is_successful_no_op() {
        let event = event(HookEventName::Stop, "s", None, None, Some("visible only"));
        let result = HookEngine::new(None).handle(&event, HostSource::Claude);
        assert!(!result.submitted);
        assert!(result.delivery_error.is_none());
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "{}");
    }

    fn event_in(name: HookEventName, session_id: &str, cwd: &str) -> HookEvent {
        HookEvent { cwd: Some(cwd.to_string()), ..event(name, session_id, None, None, None) }
    }

    fn state_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("debrief-engine-{}-{tag}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        dir
    }

    #[test]
    fn permission_request_emits_work_lane_notice_with_session_voice() {
        let dir = state_dir("permission");
        let voices = SessionVoiceStore::new(dir.join("voices.json"));
        let expected_voice = voices.claim("s1").unwrap();
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = HookEngine::new(Some(&voices)).with_state(&state, DebriefConfiguration::default());

        let result = engine.handle_at(&event_in(HookEventName::PermissionRequest, "s1", "/w/debrief"), HostSource::Claude, 100);

        assert_eq!(result.stdout, b"{}");
        let notice = result.notice.expect("권한 요청은 알림을 낸다");
        assert_eq!(notice.envelope.text, "권한 승인을 기다리고 있습니다.");
        assert_eq!(notice.envelope.voice, expected_voice);
        assert_eq!(notice.lane, SpeechLane::Work);
        assert_eq!(notice.priority, SpeechPriority::Main);
        assert!(notice.envelope.validate().is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn permission_request_still_notifies_without_state_store() {
        let result = HookEngine::new(None).handle_at(
            &event(HookEventName::PermissionRequest, "s", None, None, None),
            HostSource::Codex,
            0,
        );
        assert_eq!(result.notice.unwrap().envelope.voice, "F1");
    }

    #[test]
    fn long_turn_without_speech_notifies_on_stop() {
        let dir = state_dir("long");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = HookEngine::new(None).with_state(&state, DebriefConfiguration::default());

        let start = engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/debrief"), HostSource::Claude, 1000);
        assert!(start.notice.is_none());
        let stop = engine.handle_at(&event_in(HookEventName::Stop, "s", "/w/debrief"), HostSource::Claude, 1000 + 150);

        assert_eq!(stop.stdout, b"{}");
        assert_eq!(stop.notice.unwrap().envelope.text, "3분 걸린 작업이 끝났습니다.");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn short_spoken_or_disabled_turns_stay_silent() {
        let dir = state_dir("silent");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = HookEngine::new(None).with_state(&state, DebriefConfiguration::default());
        let stop = |at: u64| engine.handle_at(&event_in(HookEventName::Stop, "s", "/w/p"), HostSource::Claude, at);
        let start = |at: u64| engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/p"), HostSource::Claude, at);

        start(0);
        assert!(stop(59).notice.is_none(), "임계값 미만");

        start(100);
        state.update(100, |states| states.mark_spoken("s")).unwrap();
        assert!(stop(400).notice.is_none(), "에이전트가 이미 말함");

        start(500);
        assert!(stop(560).notice.is_some(), "정확히 임계값이면 알림");

        let disabled = DebriefConfiguration { long_turn_seconds: 0, ..DebriefConfiguration::default() };
        let off_engine = HookEngine::new(None).with_state(&state, disabled);
        off_engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/p"), HostSource::Claude, 600);
        let off_stop = off_engine.handle_at(&event_in(HookEventName::Stop, "s", "/w/p"), HostSource::Claude, 9000);
        assert!(off_stop.notice.is_none(), "0이면 끈다");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn briefing_reminder_sends_a_long_silent_turn_back_once_then_falls_back_to_the_notice() {
        let dir = state_dir("reminder");
        let state = SessionStateStore::new(dir.join("state.json"));
        let configuration = DebriefConfiguration { briefing_reminder: true, ..DebriefConfiguration::default() };
        let engine = engine_with(&state, configuration);
        let stop = |active: bool, at: u64, source: HostSource| {
            let event = HookEvent { stop_hook_active: active, ..event_in(HookEventName::Stop, "s", "/w/p") };
            engine.handle_at(&event, source, at)
        };
        let begin = |at: u64| engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/p"), HostSource::Claude, at);

        begin(0);
        let first = stop(false, 100, HostSource::Claude);
        assert!(first.notice.is_none());
        let output: serde_json::Value = serde_json::from_slice(&first.stdout).unwrap();
        assert_eq!(output["hookSpecificOutput"]["hookEventName"], "Stop");
        assert!(output["hookSpecificOutput"]["additionalContext"].as_str().unwrap().contains("speak"));
        let second = stop(true, 130, HostSource::Claude);
        assert_eq!(second.stdout, b"{}");
        assert_eq!(second.notice.unwrap().envelope.text, "2분 걸린 작업이 끝났습니다.", "되돌린 뒤에도 말없으면 완료 알림");

        begin(200);
        let codex: serde_json::Value = serde_json::from_slice(&stop(false, 300, HostSource::Codex).stdout).unwrap();
        assert_eq!(codex["decision"], "block");
        assert!(codex["reason"].as_str().unwrap().contains("speak"));

        begin(400);
        state.update(400, |states| states.mark_spoken("s")).unwrap();
        let spoken = stop(false, 500, HostSource::Claude);
        assert_eq!(spoken.stdout, b"{}");
        assert!(spoken.notice.is_none());

        begin(600);
        assert_eq!(stop(false, 620, HostSource::Claude).stdout, b"{}", "짧은 턴은 되돌리지 않는다");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn briefing_reminder_respects_silence_modes_and_its_default() {
        use crate::configuration::DebriefMode;
        let dir = state_dir("reminder-modes");
        let state = SessionStateStore::new(dir.join("state.json"));
        let on = |mode, muted| DebriefConfiguration { briefing_reminder: true, mode, muted, ..DebriefConfiguration::default() };
        for configuration in [on(DebriefMode::Quiet, false), on(DebriefMode::Night, false), on(DebriefMode::Normal, true), DebriefConfiguration::default()] {
            let engine = engine_with(&state, configuration);
            engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/p"), HostSource::Claude, 0);
            let stop = engine.handle_at(&event_in(HookEventName::Stop, "s", "/w/p"), HostSource::Claude, 100);
            assert_eq!(stop.stdout, b"{}");
            assert!(stop.notice.is_some(), "기존 완료 알림 그대로");
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn notice_gets_project_label_only_when_another_project_is_active() {
        let dir = state_dir("label");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = HookEngine::new(None).with_state(&state, DebriefConfiguration::default());

        let alone = engine.handle_at(&event_in(HookEventName::PermissionRequest, "a", "/w/debrief"), HostSource::Claude, 10);
        assert_eq!(alone.notice.unwrap().envelope.text, "권한 승인을 기다리고 있습니다.");

        engine.handle_at(&event_in(HookEventName::SessionStart, "b", "/w/richell"), HostSource::Claude, 20);
        let both = engine.handle_at(&event_in(HookEventName::PermissionRequest, "a", "/w/debrief"), HostSource::Claude, 30);
        assert_eq!(both.notice.unwrap().envelope.text, "debrief. 권한 승인을 기다리고 있습니다.");

        let off = DebriefConfiguration { session_label: false, ..DebriefConfiguration::default() };
        let engine = HookEngine::new(None).with_state(&state, off);
        let unlabeled = engine.handle_at(&event_in(HookEventName::PermissionRequest, "a", "/w/debrief"), HostSource::Claude, 40);
        assert_eq!(unlabeled.notice.unwrap().envelope.text, "권한 승인을 기다리고 있습니다.");
        std::fs::remove_dir_all(&dir).ok();
    }

    fn with_subtype(name: HookEventName, subtype: &str) -> HookEvent {
        HookEvent { subtype: Some(subtype.to_string()), ..event_in(name, "s", "/w/p") }
    }

    fn engine_with<'a>(state: &'a SessionStateStore, configuration: DebriefConfiguration) -> HookEngine<'a> {
        HookEngine::new(None).with_state(state, configuration)
    }

    #[test]
    fn category_voices_setting_changes_the_subagent_role_voice() {
        let dir = state_dir("category-voices");
        let state = SessionStateStore::new(dir.join("state.json"));
        let event = HookEvent {
            agent_type: Some("code-reviewer".to_string()),
            ..event_in(HookEventName::SubagentStart, "s", "/w/p")
        };
        let spoken = |configuration: DebriefConfiguration| {
            let result = engine_with(&state, configuration).handle_at(&event, HostSource::Claude, 1);
            String::from_utf8(result.stdout).unwrap()
        };

        assert!(spoken(DebriefConfiguration::default()).contains("M2"));
        let configured = DebriefConfiguration {
            category_voices: [("reviewer".to_string(), "F3".to_string())].into(),
            ..DebriefConfiguration::default()
        };
        let text = spoken(configured);
        assert!(text.contains("F3") && text.contains("제인") && !text.contains("M2"), "{text}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn stop_failure_notice_depends_on_error_type_and_ends_the_turn() {
        let dir = state_dir("failure");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = engine_with(&state, DebriefConfiguration::default());
        let text = |subtype: &str, at: u64| {
            engine
                .handle_at(&with_subtype(HookEventName::StopFailure, subtype), HostSource::Claude, at)
                .notice
                .unwrap()
                .envelope
                .text
        };
        assert_eq!(text("rate_limit", 1), "사용 한도나 서버 과부하로 작업이 멈췄습니다.");
        assert_eq!(text("billing_error", 2), "계정 문제로 작업이 멈췄습니다.");
        assert_eq!(text("unknown", 3), "API 오류로 작업이 멈췄습니다.");

        engine.handle_at(&event_in(HookEventName::UserPromptSubmit, "s", "/w/p"), HostSource::Claude, 100);
        engine.handle_at(&with_subtype(HookEventName::StopFailure, "server_error"), HostSource::Claude, 400);
        let stop = engine.handle_at(&event_in(HookEventName::Stop, "s", "/w/p"), HostSource::Claude, 500);
        assert!(stop.notice.is_none(), "실패로 끝난 턴을 완료 알림이 다시 말하지 않는다");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn notification_notices_only_for_waiting_for_input_types() {
        let dir = state_dir("notification");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = engine_with(&state, DebriefConfiguration::default());
        let notify = |subtype: &str, at: u64| {
            engine.handle_at(&with_subtype(HookEventName::Notification, subtype), HostSource::Claude, at).notice
        };

        assert_eq!(notify("idle_prompt", 1000).unwrap().envelope.text, "입력을 기다리고 있습니다.");
        assert!(notify("permission_prompt", 1000).is_none(), "권한 요청은 PermissionRequest 훅이 맡는다");
        assert!(notify("elicitation_dialog", 1000).is_none(), "Elicitation 훅이 맡는다");
        assert!(notify("idle_prompt", 1100).is_none(), "5분 쿨다운 안");
        assert!(notify("agent_needs_input", 1400).is_some());

        let missing = HookEvent { subtype: None, ..event_in(HookEventName::Notification, "s", "/w/p") };
        assert!(engine.handle_at(&missing, HostSource::Claude, 9000).notice.is_none(), "유형을 모르면 침묵");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn elicitation_and_permission_denied_notices_with_cooldown_for_the_latter() {
        let dir = state_dir("elicit");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = engine_with(&state, DebriefConfiguration::default());
        let at =
            |name: HookEventName, t: u64| engine.handle_at(&event_in(name, "s", "/w/p"), HostSource::Claude, t).notice;

        assert_eq!(at(HookEventName::Elicitation, 10).unwrap().envelope.text, "추가 입력이 필요합니다.");
        assert!(at(HookEventName::PermissionDenied, 20).is_some());
        assert!(at(HookEventName::PermissionDenied, 100).is_none(), "120초 쿨다운 안");
        assert!(at(HookEventName::PermissionDenied, 141).is_some());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn team_events_are_silent_unless_enabled_and_rate_limited() {
        let dir = state_dir("team");
        let state = SessionStateStore::new(dir.join("state.json"));
        let off = engine_with(&state, DebriefConfiguration::default());
        assert!(off
            .handle_at(&event_in(HookEventName::TeammateIdle, "s", "/w/p"), HostSource::Claude, 10)
            .notice
            .is_none());

        let on = engine_with(&state, DebriefConfiguration { team_notices: true, ..DebriefConfiguration::default() });
        let at = |name: HookEventName, t: u64| on.handle_at(&event_in(name, "s", "/w/p"), HostSource::Claude, t).notice;
        assert_eq!(at(HookEventName::TeammateIdle, 20).unwrap().envelope.text, "팀원이 대기 중입니다.");
        assert!(at(HookEventName::TeammateIdle, 30).is_none(), "쿨다운");
        assert_eq!(at(HookEventName::TaskCompleted, 30).unwrap().envelope.text, "작업 항목이 하나 끝났습니다.");
        assert!(at(HookEventName::TaskCompleted, 40).is_none(), "쿨다운");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn cooldown_events_stay_quiet_without_a_state_store() {
        let engine = HookEngine::new(None);
        let result = engine.handle_at(&event_in(HookEventName::PermissionDenied, "s", "/w/p"), HostSource::Claude, 5);
        assert!(result.notice.is_none());
    }

    #[test]
    fn session_end_forgets_the_session_without_a_notice() {
        let dir = state_dir("end");
        let state = SessionStateStore::new(dir.join("state.json"));
        let engine = engine_with(&state, DebriefConfiguration::default());
        engine.handle_at(&event_in(HookEventName::SessionStart, "a", "/w/debrief"), HostSource::Claude, 10);
        engine.handle_at(&event_in(HookEventName::SessionStart, "b", "/w/richell"), HostSource::Claude, 10);
        let both = engine.handle_at(&event_in(HookEventName::PermissionRequest, "a", "/w/debrief"), HostSource::Claude, 20);
        assert!(both.notice.unwrap().envelope.text.starts_with("debrief. "));

        let end = engine.handle_at(&event_in(HookEventName::SessionEnd, "b", "/w/richell"), HostSource::Claude, 30);
        assert_eq!(end.stdout, b"{}");
        assert!(end.notice.is_none());
        let alone = engine.handle_at(&event_in(HookEventName::PermissionRequest, "a", "/w/debrief"), HostSource::Claude, 40);
        assert_eq!(
            alone.notice.unwrap().envelope.text,
            "권한 승인을 기다리고 있습니다.",
            "끝난 세션 때문에 접두가 남지 않는다"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mode_guidance_matches_effective_state() {
        use crate::configuration::DebriefMode;
        let config = |mode, muted| DebriefConfiguration { mode, muted, ..Default::default() };
        assert_eq!(HookEngine::mode_guidance(&config(DebriefMode::Normal, false), false), "Needs a user decision? pass intent=decision.");
        assert_eq!(HookEngine::mode_guidance(&config(DebriefMode::Verbose, false), false), "Needs a user decision? pass intent=decision.");
        assert!(HookEngine::mode_guidance(&config(DebriefMode::Focus, false), false).ends_with("Mode focus: one sentence."));
        assert!(HookEngine::mode_guidance(&config(DebriefMode::Quiet, false), true).contains("Mode quiet (dnd)"));
        assert!(HookEngine::mode_guidance(&config(DebriefMode::Night, false), false).contains("speak only with intent=decision"));
        assert_eq!(HookEngine::mode_guidance(&config(DebriefMode::Night, true), false), "debrief muted: do not call speak.");
    }

    #[test]
    fn prompt_context_carries_guidance_but_subagent_context_does_not() {
        use crate::configuration::DebriefMode;
        let configuration = DebriefConfiguration { mode: DebriefMode::Quiet, ..Default::default() };
        let directory = std::env::temp_dir().join(format!("he-guidance-{}", std::process::id()));
        let state = SessionStateStore::new(directory.join("state.json"));
        let engine = HookEngine::new(None).with_state(&state, configuration).with_dnd_raised(true);
        let prompt = engine.handle_at(&event(HookEventName::UserPromptSubmit, "s", None, None, None), HostSource::Claude, 10);
        let text = String::from_utf8(prompt.stdout).unwrap();
        assert!(text.contains("Mode quiet (dnd)"), "{text}");
        assert!(text.contains("intent=decision"), "{text}");
        let context: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert!(context["hookSpecificOutput"]["additionalContext"].as_str().unwrap().chars().count() < 520);
        let sub = engine.handle_at(&event(HookEventName::SubagentStart, "s", None, Some("explore"), None), HostSource::Claude, 10);
        assert!(!String::from_utf8(sub.stdout).unwrap().contains("intent=decision"));
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn auto_compaction_speaks_before_and_chimes_after_manual_is_silent() {
        let engine = HookEngine::new(None);
        let before = engine.handle_at(&with_subtype(HookEventName::PreCompact, "auto"), HostSource::Claude, 10).notice.unwrap();
        assert_eq!(before.envelope.text, "컨텍스트를 정리하고 있습니다.");
        assert_eq!(before.cue, None);
        let after = engine.handle_at(&with_subtype(HookEventName::PostCompact, "auto"), HostSource::Claude, 20).notice.unwrap();
        assert!(after.is_cue_only());
        assert_eq!(after.cue, Some(crate::earcon::Earcon::Done));
        assert!(engine.handle_at(&with_subtype(HookEventName::PreCompact, "manual"), HostSource::Claude, 30).notice.is_none());
        assert!(engine.handle_at(&with_subtype(HookEventName::PostCompact, "manual"), HostSource::Claude, 40).notice.is_none());
    }

    #[test]
    fn notices_carry_their_earcon() {
        use crate::earcon::Earcon;
        assert_eq!(HookEngine::cue_for(HookEventName::PermissionRequest), Some(Earcon::Attention));
        assert_eq!(HookEngine::cue_for(HookEventName::Notification), Some(Earcon::Attention));
        assert_eq!(HookEngine::cue_for(HookEventName::Elicitation), Some(Earcon::Attention));
        assert_eq!(HookEngine::cue_for(HookEventName::PermissionDenied), Some(Earcon::Attention));
        assert_eq!(HookEngine::cue_for(HookEventName::StopFailure), Some(Earcon::Failure));
        assert_eq!(HookEngine::cue_for(HookEventName::Stop), Some(Earcon::Done));
        assert_eq!(HookEngine::cue_for(HookEventName::TaskCompleted), Some(Earcon::Done));
        assert_eq!(HookEngine::cue_for(HookEventName::PostCompact), Some(Earcon::Done));
        assert_eq!(HookEngine::cue_for(HookEventName::PreCompact), None);
        assert_eq!(HookEngine::cue_for(HookEventName::TeammateIdle), None);
        let notice = HookEngine::new(None).handle_at(&with_subtype(HookEventName::StopFailure, "rate_limit"), HostSource::Claude, 10).notice.unwrap();
        assert_eq!(notice.cue, Some(Earcon::Failure));
    }
}
