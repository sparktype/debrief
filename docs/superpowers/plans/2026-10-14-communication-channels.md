# 소통 채널 확장 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** debrief에 다시 듣기·끊기(CLI), 결정 대기 의도(`speak intent=decision`), 훅 모드 지침, 효과음, 자동 압축 알림을 추가한다.

**Architecture:** `SpeechRequest`에 `decision`·`cue`·`replayed` 필드를 더하고, 기존 UDS 프레임에 `control` 키를 얹어 `Inbound::{Speech, Control}`로 나눈다. 데몬은 재생 시점에 기록(최대 10개)을 쌓고, 제어 명령으로 끊기·비우기·다시 넣기를 한다. 효과음은 코드로 만든 44.1kHz 사인파 `PcmBuffer`이며 같은 소비 스레드에서 발화 직전에 재생한다.

**Tech Stack:** Rust 워크스페이스(`debrief-core` lib, `debrief` bin), std 동기 동시성(Mutex/Condvar), serde_json, libc UDS.

**Spec:** `docs/superpowers/specs/2026-10-14-communication-channels-design.md`

**진행 기록:** 체크리스트 `docs/superpowers/plans/2026-10-14-communication-channels/checklist.md`, 결정 기록 `docs/superpowers/plans/2026-10-14-communication-channels/context-notes.md`. 태스크를 끝낼 때마다 체크하고, 계획과 다르게 결정한 것은 context-notes에 덧붙인다.

## Global Constraints

- 플랫폼 macOS 14+ arm64. 새 의존성 추가 금지(효과음은 std만으로 생성).
- STT 없음, debrief 자체 텍스트 생성 없음, 외부 판단 모델 없음, PreToolUse/PostToolUse 미설치, `debrief speak` CLI 없음.
- `mute`는 발화·효과음·결정 대기를 **모두** 끈다.
- 사용자 노출 문자열은 경어체 한국어. 훅 context·MCP 설명은 기존처럼 영어.
- 새 소스 파일 첫 줄은 한국어 한 줄 역할 주석.
- 각 태스크는 실패 테스트 먼저(TDD). 완료 주장은 `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release` 통과 후에만.
- `cargo fmt`은 작업 전부터 불일치 상태다. 전체 포맷을 돌리지 말고 바꾼 줄만 주변 스타일에 맞춘다.
- 커밋 메시지는 한국어 conventional(`feat(scope): …`), 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- 기록 보존 개수 10, replay `count` 범위 1..=10, 효과음 gain = 발화 gain × 0.6, 페이드 10ms.

## Review Focus

1. 효과음 재생 중 `skip`하면 뒤따르는 발화도 재생되지 않아야 한다 — Task 6 `skip_during_earcon_drops_the_speech`.
2. 기록한 뒤 `mute`를 켜고 `replay`하면 아무것도 재생되지 않아야 한다(재생 시점 정책) — Task 6 `replay_respects_mute_at_playback_time`.
3. 대기열이 main으로 가득 찼을 때 결정 대기 요청은 거부되지 않고 가장 오래된 비결정 main을 밀어내야 한다 — Task 4 `decision_evicts_oldest_plain_main_when_full`.
4. `replay n`에서 n이 기록보다 크면 있는 만큼만 오래된 순으로 재생하고 오류가 없어야 한다 — Task 6 `replay_more_than_history_plays_what_exists`.
5. 텍스트도 효과음도 없는 요청(구버전·잘못된 클라이언트)은 합성 실패 기록 없이 조용히 버려야 한다 — Task 5 `empty_text_without_cue_is_dropped_silently`.

---

## File Structure

| 파일 | 역할 | 태스크 |
|---|---|---|
| `crates/debrief-core/src/earcon.rs` (신규) | `Earcon` enum과 사인파 `PcmBuffer` 생성 | 1 |
| `crates/debrief-core/src/speech_request.rs` | `decision`·`cue`·`replayed` 필드, `is_cue_only` | 2 |
| `crates/debrief-core/src/unix_socket.rs` | 발화 코덱 새 필드, 제어 프레임 코덱, `accept → Inbound`, `send_control` | 2, 6 |
| `crates/debrief-core/src/mode_policy.rs` | `decision` 인자 | 3 |
| `crates/debrief-core/src/speech_queue.rs` | 결정 대기 순서, `clear`, `enqueue_replay` | 4 |
| `crates/debrief-core/src/configuration.rs` | `earcons` 설정 | 5 |
| `crates/debrief-core/src/debrief_daemon.rs` | 효과음 재생, 기록, `control` 처리 | 5, 6 |
| `crates/debrief-core/src/daemon_control.rs` (신규) | `Control`·`Inbound` | 6 |
| `crates/debrief-core/src/resident_service.rs` | 소스 트레이트 변경 반영 | 6 |
| `crates/debrief-core/src/debrief_command.rs`, `crates/debrief/src/main.rs` | `skip`·`replay` CLI | 7 |
| `crates/debrief-core/src/mcp_speak_tool.rs`, `mcp_server.rs` | `intent`, 응답 `mode`·`muted` | 8 |
| `crates/debrief-core/src/hook_engine.rs`, `hook_command_runner.rs` | 모드 지침, 효과음 매핑, 압축 알림 | 9, 10 |
| `crates/debrief-core/src/hook_event.rs`, `hook_adapter.rs`, `embedded_templates.rs` | 압축 이벤트, `trigger`, 설치 목록, 스킬 문구 | 10, 11 |
| 문서 | CLAUDE.md, README.md, ONBOARDING.md, CHANGELOG.md | 11 |

---

### Task 1: Earcon 사인파 생성

**Files:**
- Create: `crates/debrief-core/src/earcon.rs`
- Modify: `crates/debrief-core/src/lib.rs` (모듈 등록과 re-export)

**Interfaces:**
- Produces: `pub enum Earcon { Decision, Attention, Failure, Done }` (`Debug, Clone, Copy, PartialEq, Eq`), `Earcon::as_str(&self) -> &'static str`, `Earcon::from_str_value(&str) -> Option<Earcon>`, `Earcon::buffer(&self) -> PcmBuffer`, `Earcon::SAMPLE_RATE: f64 = 44_100.0`.

- [ ] **Step 1: 실패 테스트 작성** — `crates/debrief-core/src/earcon.rs`에 모듈 골격과 테스트를 만든다.

```rust
// 결정·주의·실패·완료를 알리는 짧은 사인파 효과음을 코드로 만든다
use crate::tts_backend::PcmBuffer;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Earcon {
    Decision,
    Attention,
    Failure,
    Done,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for earcon in [Earcon::Decision, Earcon::Attention, Earcon::Failure, Earcon::Done] {
            assert_eq!(Earcon::from_str_value(earcon.as_str()), Some(earcon));
        }
        assert_eq!(Earcon::from_str_value("beep"), None);
    }

    #[test]
    fn buffers_have_expected_length_and_shape() {
        let cases = [(Earcon::Decision, 5292 * 2), (Earcon::Attention, 6615), (Earcon::Failure, 6174 * 2), (Earcon::Done, 4410)];
        for (earcon, count) in cases {
            let buffer = earcon.buffer();
            assert_eq!(buffer.sample_rate, 44_100.0);
            assert_eq!(buffer.channels, 1);
            assert_eq!(buffer.samples.len(), count, "{earcon:?}");
            assert!(buffer.samples.first().unwrap().abs() < 1e-3, "{earcon:?} 시작 클릭");
            assert!(buffer.samples.last().unwrap().abs() < 1e-3, "{earcon:?} 끝 클릭");
            assert!(buffer.samples.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
            assert!(buffer.samples.iter().any(|s| s.abs() > 0.1), "{earcon:?} 무음");
        }
    }
}
```

`lib.rs`에 `pub mod earcon;`와 `pub use earcon::Earcon;`를 기존 모듈 목록 순서(알파벳)에 맞춰 넣는다.

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core earcon`
Expected: 컴파일 실패 — `no function or associated item named 'from_str_value'`, `buffer`.

- [ ] **Step 3: 구현** — enum 아래에 추가한다.

```rust
impl Earcon {
    pub const SAMPLE_RATE: f64 = 44_100.0;
    const FADE_SECONDS: f64 = 0.010;

    pub fn as_str(&self) -> &'static str {
        match self {
            Earcon::Decision => "decision",
            Earcon::Attention => "attention",
            Earcon::Failure => "failure",
            Earcon::Done => "done",
        }
    }

    pub fn from_str_value(value: &str) -> Option<Earcon> {
        match value {
            "decision" => Some(Earcon::Decision),
            "attention" => Some(Earcon::Attention),
            "failure" => Some(Earcon::Failure),
            "done" => Some(Earcon::Done),
            _ => None,
        }
    }

    /// (주파수 Hz, 길이 초) 순서열과 진폭. 완료음은 약하게 낸다.
    fn shape(&self) -> (&'static [(f64, f64)], f64) {
        match self {
            Earcon::Decision => (&[(660.0, 0.12), (880.0, 0.12)], 0.5),
            Earcon::Attention => (&[(740.0, 0.15)], 0.5),
            Earcon::Failure => (&[(587.0, 0.14), (440.0, 0.14)], 0.5),
            Earcon::Done => (&[(523.0, 0.10)], 0.3),
        }
    }

    pub fn buffer(&self) -> PcmBuffer {
        let (tones, amplitude) = self.shape();
        let fade = (Self::FADE_SECONDS * Self::SAMPLE_RATE) as usize;
        let mut samples = Vec::new();
        for &(frequency, seconds) in tones {
            let count = (seconds * Self::SAMPLE_RATE).round() as usize;
            for index in 0..count {
                // 톤마다 앞뒤를 선형 페이드해 클릭음을 막는다.
                let envelope = (index.min(count - 1 - index) as f64 / fade as f64).min(1.0);
                let phase = 2.0 * std::f64::consts::PI * frequency * index as f64 / Self::SAMPLE_RATE;
                samples.push((amplitude * envelope * phase.sin()) as f32);
            }
        }
        PcmBuffer { sample_rate: Self::SAMPLE_RATE, channels: 1, samples }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `cargo test -p debrief-core earcon`
Expected: 2 passed.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/earcon.rs crates/debrief-core/src/lib.rs
git commit -m "feat(earcon): 결정·주의·실패·완료 사인파 효과음 생성기 추가"
```

---

### Task 2: SpeechRequest 새 필드와 발화 코덱

**Files:**
- Modify: `crates/debrief-core/src/speech_request.rs`
- Modify: `crates/debrief-core/src/unix_socket.rs:166-221` (`decode_speech_request`, `encode_speech_request`) 및 `DirectSpeechCommand::submit`(~486)
- Modify (리터럴에 새 필드 추가): `hook_engine.rs:170`, `mcp_speak_tool.rs:90`, `debrief_daemon.rs` 테스트(307, 366, 373), `speech_queue.rs` 테스트(118), `unix_socket.rs` 테스트(529, 545, 574)

**Interfaces:**
- Consumes: `Earcon` (Task 1).
- Produces: `SpeechRequest { …, pub decision: bool, pub cue: Option<Earcon>, pub replayed: bool }`, `SpeechRequest::is_cue_only(&self) -> bool`. 소켓 JSON 키 `"decision"`(bool), `"cue"`(문자열 또는 null). `replayed`는 직렬화하지 않는다.

- [ ] **Step 1: 실패 테스트 작성** — `unix_socket.rs` tests 모듈 끝에 추가한다.

```rust
    fn fixture(text: &str) -> SpeechRequest {
        SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: text.to_string(), voice: "F1".to_string(), speed: 1.0, volume: 0.5 },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Work,
            emotion: SpeechEmotion::Neutral,
            agent_type: None,
            decision: false,
            cue: None,
            replayed: false,
        }
    }

    #[test]
    fn speech_codec_round_trips_decision_and_cue_but_not_replayed() {
        let request = SpeechRequest { decision: true, cue: Some(crate::earcon::Earcon::Decision), replayed: true, ..fixture("결정") };
        let decoded = UnixSocketServer::decode_speech_request(&UnixSocketServer::encode_speech_request(&request)).unwrap();
        assert!(decoded.decision);
        assert_eq!(decoded.cue, Some(crate::earcon::Earcon::Decision));
        assert!(!decoded.replayed, "replayed는 프레임에 실리지 않는다");
    }

    #[test]
    fn legacy_speech_frame_without_new_fields_decodes_with_defaults() {
        let payload = br#"{"envelope":{"v":1,"text":"hi","voice":"F1","speed":1.0,"volume":0.5},"priority":"main","lane":"work","emotion":"neutral"}"#;
        let decoded = UnixSocketServer::decode_speech_request(payload).unwrap();
        assert!(!decoded.decision);
        assert_eq!(decoded.cue, None);
    }

    #[test]
    fn cue_only_means_empty_text_with_cue() {
        assert!(SpeechRequest { cue: Some(crate::earcon::Earcon::Done), ..fixture("") }.is_cue_only());
        assert!(!fixture("").is_cue_only());
        assert!(!SpeechRequest { cue: Some(crate::earcon::Earcon::Done), ..fixture("x") }.is_cue_only());
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core unix_socket`
Expected: 컴파일 실패 — `struct SpeechRequest has no field named decision`.

- [ ] **Step 3: 구현**

`speech_request.rs`:

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct SpeechRequest {
    pub envelope: SpeechEnvelope,
    pub priority: SpeechPriority,
    pub lane: SpeechLane,
    pub emotion: SpeechEmotion,
    pub agent_type: Option<String>,
    /// 사용자 결정 대기 — ModePolicy가 상한·companion off·subagent 억제를 건너뛴다(mute는 아님).
    pub decision: bool,
    /// 발화 직전에 낼 효과음.
    pub cue: Option<crate::earcon::Earcon>,
    /// 데몬 내부 표시: replay로 다시 넣은 요청은 기록에 쌓지 않는다. 프레임에 실리지 않는다.
    pub replayed: bool,
}

impl SpeechRequest {
    pub fn is_main(&self) -> bool {
        matches!(self.priority, SpeechPriority::Main)
    }

    /// 텍스트 없이 효과음만 내는 요청(훅 전용).
    pub fn is_cue_only(&self) -> bool {
        self.envelope.text.is_empty() && self.cue.is_some()
    }
}
```

`unix_socket.rs` `decode_speech_request`의 마지막 두 줄을 바꾼다.

```rust
        let agent_type = value.get("agentType").and_then(|v| v.as_str()).map(|s| s.to_string());
        let decision = value.get("decision").and_then(|v| v.as_bool()).unwrap_or(false);
        let cue = value.get("cue").and_then(|v| v.as_str()).and_then(crate::earcon::Earcon::from_str_value);
        Some(SpeechRequest { envelope, priority, lane, emotion, agent_type, decision, cue, replayed: false })
```

`encode_speech_request`의 JSON에 두 키를 더한다(`"agentType"` 다음).

```rust
            "agentType": request.agent_type,
            "decision": request.decision,
            "cue": request.cue.map(|cue| cue.as_str()),
```

위 Files 목록의 모든 `SpeechRequest { … }` 리터럴에 `decision: false, cue: None, replayed: false`를 추가한다(`hook_engine.rs:170`의 알림은 Task 10에서 `cue`를 채운다. 여기서는 `None`).

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과(새 테스트 3개 포함).

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src
git commit -m "feat(speech): 요청에 결정 대기·효과음 필드를 더하고 소켓 코덱에 싣는다"
```

---

### Task 3: ModePolicy 결정 대기 예외

**Files:**
- Modify: `crates/debrief-core/src/mode_policy.rs`
- Modify: `crates/debrief-core/src/debrief_daemon.rs:103,183` (호출부에 `request.decision` 전달)

**Interfaces:**
- Produces: `ModePolicy::admit(priority, lane, requested_volume, configuration, decision: bool) -> Option<f64>`.

- [ ] **Step 1: 실패 테스트 작성** — `mode_policy.rs` tests에 추가하고, 기존 테스트의 `admit(...)` 호출 끝에 `, false`를 붙인다.

```rust
    #[test]
    fn decision_ignores_ceiling_companion_off_and_mode_but_not_mute() {
        let night = DebriefConfiguration { mode: DebriefMode::Night, companion_enabled: false, ..Default::default() };
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.9, &night, true), Some(0.9));
        let quiet = config(DebriefMode::Quiet, false);
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 1.5, &quiet, true), Some(1.0));
        let muted = config(DebriefMode::Normal, true);
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.9, &muted, true), None);
    }

    #[test]
    fn decision_on_subagent_is_ignored() {
        let focus = config(DebriefMode::Focus, false);
        assert_eq!(ModePolicy::admit(SpeechPriority::Subagent, SpeechLane::Work, 0.9, &focus, true), None);
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core mode_policy`
Expected: 컴파일 실패 — `this function takes 4 arguments but 5 arguments were supplied`.

- [ ] **Step 3: 구현** — 시그니처에 `decision: bool`을 더하고 mute 검사 바로 뒤에 넣는다.

```rust
    pub fn admit(
        priority: SpeechPriority,
        lane: SpeechLane,
        requested_volume: f64,
        configuration: &DebriefConfiguration,
        decision: bool,
    ) -> Option<f64> {
        if configuration.muted || !requested_volume.is_finite() {
            return None;
        }

        // 결정 대기는 main에서만 인정한다 — 서브에이전트는 사용자에게 브리핑하지 않는다.
        if decision && matches!(priority, SpeechPriority::Main) {
            return Some(requested_volume.clamp(0.0, 1.0));
        }
        // … 기존 본문 그대로 …
```

`debrief_daemon.rs`의 두 호출을 `ModePolicy::admit(request.priority, request.lane, request.envelope.volume, &configuration, request.decision)`(소비 스레드 쪽은 `&configuration()`)로 바꾼다.

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/mode_policy.rs crates/debrief-core/src/debrief_daemon.rs
git commit -m "feat(policy): 결정 대기 발화는 mute 외의 억제를 건너뛴다"
```

---

### Task 4: SpeechQueue 결정 순서·비우기·replay 넣기

**Files:**
- Modify: `crates/debrief-core/src/speech_queue.rs`

**Interfaces:**
- Consumes: `SpeechRequest.decision`, `SpeechRequest.replayed` (Task 2).
- Produces: `SpeechQueue::clear(&self)`, `SpeechQueue::enqueue_replay(&self, request: SpeechRequest) -> QueueDecision` (중복 창 무시, `replayed = true`로 넣음).

- [ ] **Step 1: 실패 테스트 작성** — tests의 `request` 헬퍼 리터럴에는 Task 2에서 새 필드가 들어가 있다. 아래를 추가한다.

```rust
    fn decision(text: &str) -> SpeechRequest {
        SpeechRequest { decision: true, ..request(SpeechPriority::Main, text) }
    }

    #[test]
    fn decision_goes_before_plain_mains_but_after_earlier_decisions() {
        let queue = SpeechQueue::new(8, Duration::ZERO);
        queue.enqueue(request(SpeechPriority::Main, "plain-1"));
        queue.enqueue(decision("decide-1"));
        queue.enqueue(request(SpeechPriority::Main, "plain-2"));
        queue.enqueue(decision("decide-2"));
        assert_eq!(queue.pending_texts(), vec!["decide-1", "decide-2", "plain-1", "plain-2"]);
    }

    #[test]
    fn decision_evicts_oldest_plain_main_when_full() {
        let queue = SpeechQueue::new(2, Duration::ZERO);
        queue.enqueue(request(SpeechPriority::Main, "a"));
        queue.enqueue(request(SpeechPriority::Main, "b"));
        assert_eq!(queue.enqueue(decision("d")), QueueDecision::Accepted);
        assert_eq!(queue.pending_texts(), vec!["d", "b"]);
        assert_eq!(queue.enqueue(request(SpeechPriority::Main, "c")), QueueDecision::RejectedCapacity);
    }

    #[test]
    fn clear_empties_pending() {
        let queue = SpeechQueue::new(8, Duration::ZERO);
        queue.enqueue(request(SpeechPriority::Main, "a"));
        queue.clear();
        assert!(queue.pending_texts().is_empty());
    }

    #[test]
    fn replay_bypasses_duplicate_window_and_marks_request() {
        let queue = SpeechQueue::new(8, Duration::from_secs(60));
        assert_eq!(queue.enqueue(request(SpeechPriority::Main, "same")), QueueDecision::Accepted);
        assert_eq!(queue.next().envelope.text, "same");
        assert_eq!(queue.enqueue(request(SpeechPriority::Main, "same")), QueueDecision::RejectedDuplicate);
        assert_eq!(queue.enqueue_replay(request(SpeechPriority::Main, "same")), QueueDecision::Accepted);
        assert!(queue.next().replayed);
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core speech_queue`
Expected: 컴파일 실패 — `no method named 'clear'`, `enqueue_replay`.

- [ ] **Step 3: 구현** — `enqueue`의 중복 검사 이후 부분을 `insert`로 빼고 두 공개 메서드가 공유한다.

```rust
    pub fn enqueue(&self, request: SpeechRequest) -> QueueDecision {
        let mut state = self.state.lock().unwrap();
        let now = Instant::now();
        state.recent_digests.retain(|(_, accepted_at)| now.duration_since(*accepted_at) < self.duplicate_window);

        let digest = Self::digest(&request.envelope);
        if state.recent_digests.iter().any(|(value, _)| *value == digest) {
            return QueueDecision::RejectedDuplicate;
        }
        let decision = self.insert(&mut state, request);
        if decision == QueueDecision::Accepted {
            state.recent_digests.push((digest, now));
        }
        decision
    }

    /// 다시 듣기 — 방금 들은 발화라 중복 창 안이므로 그 검사를 건너뛴다.
    pub fn enqueue_replay(&self, mut request: SpeechRequest) -> QueueDecision {
        request.replayed = true;
        let mut state = self.state.lock().unwrap();
        self.insert(&mut state, request)
    }

    pub fn clear(&self) {
        self.state.lock().unwrap().pending.clear();
    }

    fn insert(&self, state: &mut QueueState, request: SpeechRequest) -> QueueDecision {
        if request.is_main() {
            state.pending.retain(|pending| pending.is_main());
        }
        let is_decision = request.decision && request.is_main();

        if state.pending.len() >= self.capacity {
            let evictable = state.pending.iter().position(|pending| !pending.is_main()).or_else(|| {
                // 결정 대기는 거부하지 않고 가장 오래된 일반 main을 밀어낸다.
                is_decision.then(|| state.pending.iter().position(|pending| !pending.decision)).flatten()
            });
            match evictable {
                Some(index) => {
                    state.pending.remove(index);
                }
                None => return QueueDecision::RejectedCapacity,
            }
        }

        if is_decision {
            let index = state.pending.iter().position(|pending| !pending.decision).unwrap_or(state.pending.len());
            state.pending.insert(index, request);
        } else {
            state.pending.push_back(request);
        }
        self.condvar.notify_one();
        QueueDecision::Accepted
    }
```

주의: 기존 `enqueue`는 용량 거부 전에 digest를 넣지 않았다. 위 구현도 `Accepted`일 때만 넣어 동작이 같다(`next_resumes_after_capacity_rejection` 테스트가 지킨다).

- [ ] **Step 4: 통과 확인**

Run: `cargo test -p debrief-core speech_queue`
Expected: 기존 5개 + 새 4개 통과.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/speech_queue.rs
git commit -m "feat(queue): 결정 대기 우선 배치, 대기열 비우기, replay 넣기 추가"
```

---

### Task 5: 데몬 효과음 재생·기록·earcons 설정

**Files:**
- Modify: `crates/debrief-core/src/configuration.rs` (`earcons` 필드)
- Modify: `crates/debrief-core/src/debrief_daemon.rs` (`history`, `consume`, `submit`)

**Interfaces:**
- Consumes: `Earcon::buffer` (1), `SpeechRequest.cue/is_cue_only/replayed` (2), `ModePolicy::admit(.., decision)` (3).
- Produces: `DebriefConfiguration.earcons: bool` (기본 true, JSON `earcons`), `DebriefDaemon::HISTORY_CAPACITY: usize = 10`, `DebriefDaemon::history_texts(&self) -> Vec<String>`(테스트·진단용), 내부 `history: Arc<Mutex<VecDeque<SpeechRequest>>>`.

- [ ] **Step 1: 실패 테스트 작성**

`configuration.rs` tests:

```rust
    #[test]
    fn earcons_default_on_and_load_missing_as_on() {
        assert!(DebriefConfiguration::default().earcons);
        let directory = temporary_directory();
        let url = directory.join("config.json");
        fs::write(&url, r#"{"earcons":false}"#).unwrap();
        assert!(!DebriefConfiguration::load(&url).earcons);
        fs::write(&url, "{}").unwrap();
        assert!(DebriefConfiguration::load(&url).earcons);
        fs::remove_dir_all(&directory).ok();
    }
```

`debrief_daemon.rs` tests (효과음 버퍼 첫 샘플은 0이라 `RecordingAudio` 마커는 0이다):

```rust
    fn with_cue(text: &str, cue: crate::earcon::Earcon) -> SpeechRequest {
        SpeechRequest { cue: Some(cue), ..request(SpeechPriority::Main, text, 0.5) }
    }

    #[test]
    fn cue_plays_before_speech_at_reduced_gain() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, None);
        daemon.submit(with_cue("hello", crate::earcon::Earcon::Attention));
        daemon.audio.wait_until_count(2);
        assert_eq!(daemon.audio.markers(), vec![0, 5]);
        let gains = daemon.audio.gains();
        assert!((gains[0] - gains[1] * 0.6).abs() < 1e-9, "{gains:?}");
        daemon.shutdown();
    }

    #[test]
    fn earcons_off_skips_the_cue() {
        let config = DebriefConfiguration { earcons: false, ..Default::default() };
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), move || config.clone(), None);
        daemon.submit(with_cue("hello", crate::earcon::Earcon::Attention));
        daemon.audio.wait_until_count(1);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(daemon.audio.markers(), vec![5]);
        daemon.shutdown();
    }

    #[test]
    fn cue_only_request_skips_synthesis_and_history() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, None);
        daemon.submit(with_cue("", crate::earcon::Earcon::Done));
        daemon.audio.wait_until_count(1);
        assert!(daemon.backend.texts().is_empty());
        assert!(daemon.history_texts().is_empty());
        daemon.shutdown();
    }

    #[test]
    fn empty_text_without_cue_is_dropped_silently() {
        let entries: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = entries.clone();
        let record: Arc<ErrorRecorder> = Arc::new(move |c, _, _| sink.lock().unwrap().push(c.to_string()));
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, Some(record));
        assert_eq!(daemon.submit(request(SpeechPriority::Main, "", 0.5)), None);
        std::thread::sleep(Duration::from_millis(50));
        assert!(daemon.backend.texts().is_empty());
        assert!(entries.lock().unwrap().is_empty());
        daemon.shutdown();
    }

    #[test]
    fn history_keeps_last_ten_played_requests() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(16, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, None);
        for index in 0..12 {
            daemon.submit(request(SpeechPriority::Main, &format!("t{index:02}"), 0.5));
            daemon.audio.wait_until_count(index + 1);
        }
        let expected: Vec<String> = (2..12).map(|i| format!("t{i:02}")).collect();
        assert_eq!(daemon.history_texts(), expected);
        daemon.shutdown();
    }
```

참고: `history_keeps_last_ten_played_requests`는 main이 대기 중인 subagent만 밀어내므로 순서대로 모두 재생된다. 매 제출 뒤 재생을 기다려 대기열 용량과 무관하게 만든다.

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core debrief_daemon configuration`
Expected: 컴파일 실패 — `no field earcons`, `no method history_texts`.

- [ ] **Step 3: 구현**

`configuration.rs`: 필드(`team_notices` 다음), 기본값 함수, `Default`에 추가.

```rust
    /// 결정·주의·실패·완료 알림 앞의 짧은 효과음. 일반 브리핑에는 없다.
    #[serde(default = "default_earcons")]
    pub earcons: bool,
```

```rust
fn default_earcons() -> bool {
    true
}
```

`Default`에 `earcons: default_earcons(),`.

`debrief_daemon.rs`:

```rust
pub struct DebriefDaemon<B: TtsBackend, A: AudioPlaying> {
    // … 기존 필드 …
    history: Arc<Mutex<std::collections::VecDeque<SpeechRequest>>>,
}
```

`new`에 `history: Arc::new(Mutex::new(std::collections::VecDeque::new())),`. 상수와 접근자:

```rust
    pub const HISTORY_CAPACITY: usize = 10;
    const CUE_GAIN_RATIO: f64 = 0.6;

    pub fn history_texts(&self) -> Vec<String> {
        self.history.lock().unwrap().iter().map(|r| r.envelope.text.clone()).collect()
    }
```

`submit` 첫 부분(종료 검사 뒤)에 추가:

```rust
        // 텍스트도 효과음도 없는 요청은 합성할 것이 없다.
        if request.envelope.text.is_empty() && request.cue.is_none() {
            return None;
        }
```

`submit`의 워커 생성 부분과 `consume` 시그니처에 `history` clone을 넘긴다(`let history = self.history.clone();` → `Self::consume(queue, backend, audio, configuration, record_error, shared_state, history)`). `consume`의 `match backend.synthesize(...)` 블록을 아래로 바꾼다.

```rust
            let buffer = if request.is_cue_only() {
                None
            } else {
                match backend.synthesize(&request.envelope.text, &request.envelope.voice, request.envelope.speed) {
                    Ok(buffer) => Some(buffer),
                    Err(error) => {
                        // 실패한 항목은 버리고 계속한다; 메뉴 진단을 위해 표면화한다.
                        if let Some(record_error) = &record_error {
                            let detail: String = format!("{error:?}").chars().take(80).collect();
                            record_error("tts", "synthesis_or_playback", &format!("합성 또는 재생에 실패했습니다: {detail}"));
                        }
                        let mut guard = state.lock().unwrap();
                        guard.active = None;
                        guard.discard_active = false;
                        continue;
                    }
                }
            };

            let current = configuration();
            let admitted = ModePolicy::admit(request.priority, request.lane, request.envelope.volume, &current, request.decision);
            // `if let` 조건에 락을 두면 재생 내내 잡혀 skip이 교착된다 — 매번 짧게 잡고 놓는다.
            let discarded = || state.lock().unwrap().discard_active;
            if let Some(gain) = admitted.filter(|_| !discarded()) {
                if let (Some(cue), true) = (request.cue, current.earcons) {
                    let _ = audio.play(&cue.buffer(), gain * Self::CUE_GAIN_RATIO);
                }
                // 효과음 도중 skip되면 발화도 버린다.
                if let Some(buffer) = buffer.as_ref().filter(|_| !discarded()) {
                    let _ = audio.play(buffer, gain);
                    if !request.replayed {
                        let mut history = history.lock().unwrap();
                        history.push_back(request.clone());
                        while history.len() > Self::HISTORY_CAPACITY {
                            history.pop_front();
                        }
                    }
                }
            }
```

(`continue` 경로와 정상 경로 모두 루프 끝의 `active = None` 정리를 지킨다. 정상 경로는 기존 루프 끝 블록이 처리한다.)

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과(기존 `preserves_order_clamps_gain_and_continues_after_synthesis_failure` 포함 — 효과음 없는 요청이라 마커가 그대로다).

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/configuration.rs crates/debrief-core/src/debrief_daemon.rs
git commit -m "feat(daemon): 발화 앞 효과음 재생과 다시 듣기 기록 추가"
```

---

### Task 6: 제어 프레임·데몬 control 처리

**Files:**
- Create: `crates/debrief-core/src/daemon_control.rs`
- Modify: `crates/debrief-core/src/lib.rs`
- Modify: `crates/debrief-core/src/unix_socket.rs` (`accept`/`accept_one`/`handle_accepted` → `Inbound`, `decode_inbound`, `encode_control`, `UnixSocketClient::send_control`, `submit` 공용화)
- Modify: `crates/debrief-core/src/debrief_daemon.rs` (`SpeechRequestSource::accept → Inbound`, `run` 분기, `control`, `ensure_worker` 추출)
- Modify: `crates/debrief-core/src/resident_service.rs:32-40,161-170` (소스 구현 두 곳)

**Interfaces:**
- Consumes: `SpeechQueue::clear/enqueue_replay` (4), `history` (5).
- Produces: `pub enum Control { Skip, SkipAll, Replay(u8) }`, `pub enum Inbound { Speech(SpeechRequest), Control(Control) }`, `trait SpeechRequestSource { fn accept(&self) -> Result<Inbound, UnixSocketError>; fn close(&self); }`, `DebriefDaemon::control(&self, control: Control)`, `UnixSocketClient::send_control(&self, control: &Control) -> Result<(), UnixSocketError>`. 프레임: `{"control":"skip"}`, `{"control":"skipAll"}`, `{"control":"replay","count":n}`.

- [ ] **Step 1: `daemon_control.rs` 작성** (타입만, 동작 없음)

```rust
// 데몬 소켓으로 들어오는 제어 명령(끊기·비우기·다시 듣기)과 수신 항목 구분
use crate::speech_request::SpeechRequest;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    Skip,
    SkipAll,
    /// 최근 기록 n개(1..=10)를 오래된 순으로 다시 재생한다.
    Replay(u8),
}

impl Control {
    pub const MAXIMUM_REPLAY: u8 = 10;
}

#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    Speech(SpeechRequest),
    Control(Control),
}
```

`lib.rs`: `pub mod daemon_control;`, `pub use daemon_control::{Control, Inbound};`.

- [ ] **Step 2: 실패 테스트 작성**

`unix_socket.rs` tests:

```rust
    #[test]
    fn control_frames_round_trip_and_bad_counts_are_rejected() {
        use crate::daemon_control::{Control, Inbound};
        for control in [Control::Skip, Control::SkipAll, Control::Replay(1), Control::Replay(10)] {
            let payload = UnixSocketServer::encode_control(&control);
            assert_eq!(UnixSocketServer::decode_inbound(&payload), Some(Inbound::Control(control)));
        }
        for bad in [r#"{"control":"replay","count":0}"#, r#"{"control":"replay","count":11}"#, r#"{"control":"replay"}"#, r#"{"control":"rewind"}"#] {
            assert_eq!(UnixSocketServer::decode_inbound(bad.as_bytes()), None, "{bad}");
        }
        let speech = UnixSocketServer::encode_speech_request(&fixture("hi"));
        assert!(matches!(UnixSocketServer::decode_inbound(&speech), Some(Inbound::Speech(_))));
    }

    #[test]
    fn client_sends_control_and_server_accepts_it() {
        use crate::daemon_control::{Control, Inbound};
        let directory = temporary_directory();
        let url = directory.join("c.sock");
        let server = std::sync::Arc::new(UnixSocketServer::new(url.clone()).unwrap());
        let accepting = server.clone();
        let handle = std::thread::spawn(move || accepting.accept());
        UnixSocketClient::new(url).send_control(&Control::Replay(3)).unwrap();
        assert_eq!(handle.join().unwrap().unwrap(), Inbound::Control(Control::Replay(3)));
        fs::remove_dir_all(&directory).ok();
    }
```

`debrief_daemon.rs` tests:

```rust
    use crate::daemon_control::Control;

    #[test]
    fn skip_stops_only_the_active_request() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(Some(6)), DebriefConfiguration::default, None);
        daemon.submit(request(SpeechPriority::Main, "first.", 0.5)); // 마커 6, 재생에서 막힌다
        daemon.audio.wait_until_started(6);
        daemon.submit(request(SpeechPriority::Main, "next", 0.5));
        daemon.control(Control::Skip);
        daemon.audio.wait_until_count(2);
        assert_eq!(daemon.audio.markers(), vec![6, 4]);
        assert_eq!(daemon.audio.stop_count(), 1);
        daemon.shutdown();
    }

    #[test]
    fn skip_all_also_clears_the_queue() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(Some(6)), DebriefConfiguration::default, None);
        daemon.submit(request(SpeechPriority::Main, "first.", 0.5));
        daemon.audio.wait_until_started(6);
        daemon.submit(request(SpeechPriority::Main, "next", 0.5));
        daemon.control(Control::SkipAll);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(daemon.audio.markers(), vec![6]);
        daemon.shutdown();
    }

    #[test]
    fn skip_during_earcon_drops_the_speech() {
        // 효과음 마커는 0이다 — 효과음 재생에서 막아 두고 skip한다.
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(Some(0)), DebriefConfiguration::default, None);
        daemon.submit(with_cue("hello", crate::earcon::Earcon::Attention));
        daemon.audio.wait_until_started(0);
        daemon.control(Control::Skip);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(daemon.audio.markers(), vec![0]);
        assert!(daemon.history_texts().is_empty());
        daemon.shutdown();
    }

    #[test]
    fn replay_plays_oldest_first_and_does_not_grow_history() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::from_secs(60)), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, None);
        for (index, text) in ["a", "bb", "ccc"].into_iter().enumerate() {
            daemon.submit(request(SpeechPriority::Main, text, 0.5));
            daemon.audio.wait_until_count(index + 1);
        }
        daemon.control(Control::Replay(2));
        daemon.audio.wait_until_count(5);
        assert_eq!(daemon.audio.markers(), vec![1, 2, 3, 2, 3]);
        assert_eq!(daemon.history_texts(), vec!["a", "bb", "ccc"]);
        daemon.shutdown();
    }

    #[test]
    fn replay_more_than_history_plays_what_exists() {
        let daemon = DebriefDaemon::new(None, SpeechQueue::new(8, Duration::ZERO), RecordingBackend::new(None), RecordingAudio::new(None), DebriefConfiguration::default, None);
        daemon.control(Control::Replay(3)); // 빈 기록 — 아무 일도 없어야 한다
        daemon.submit(request(SpeechPriority::Main, "only", 0.5));
        daemon.audio.wait_until_count(1);
        daemon.control(Control::Replay(10));
        daemon.audio.wait_until_count(2);
        assert_eq!(daemon.audio.markers(), vec![4, 4]);
        daemon.shutdown();
    }

    #[test]
    fn replay_respects_mute_at_playback_time() {
        let muted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = muted.clone();
        let daemon = DebriefDaemon::new(
            None,
            SpeechQueue::new(8, Duration::ZERO),
            RecordingBackend::new(None),
            RecordingAudio::new(None),
            move || DebriefConfiguration { muted: flag.load(std::sync::atomic::Ordering::SeqCst), ..Default::default() },
            None,
        );
        daemon.submit(request(SpeechPriority::Main, "said", 0.5));
        daemon.audio.wait_until_count(1);
        muted.store(true, std::sync::atomic::Ordering::SeqCst);
        daemon.control(Control::Replay(1));
        daemon.backend.wait_until_count(2);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(daemon.audio.markers(), vec![4]);
        daemon.shutdown();
    }
```

기존 테스트 소스 세 곳(`WaitingSource`, `SourceAdapter`, `SequenceSource`)의 `accept` 반환을 `Result<Inbound, UnixSocketError>`로 바꾸고 `Ok(request)`를 `Ok(Inbound::Speech(request))`로 감싼다.

- [ ] **Step 3: 실패 확인**

Run: `cargo test -p debrief-core`
Expected: 컴파일 실패 — `decode_inbound`, `encode_control`, `send_control`, `control` 없음.

- [ ] **Step 4: 소켓 구현**

`unix_socket.rs`:

```rust
    pub fn accept(&self) -> Result<crate::daemon_control::Inbound, UnixSocketError> {
        self.accept_one()
    }
```

`accept_one`·`handle_accepted`의 반환형을 `Inbound`로 바꾸고, `handle_accepted` 안의 디코딩 줄을 교체한다.

```rust
            let inbound = Self::decode_inbound(&payload).ok_or(UnixSocketError::InvalidFrame)?;
            Self::write_all(&[0x06], descriptor)?;
            Ok(inbound)
```

```rust
    fn decode_inbound(payload: &[u8]) -> Option<crate::daemon_control::Inbound> {
        use crate::daemon_control::{Control, Inbound};
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let Some(control) = value.get("control") else {
            return Self::decode_speech_request(payload).map(Inbound::Speech);
        };
        let control = match control.as_str()? {
            "skip" => Control::Skip,
            "skipAll" => Control::SkipAll,
            "replay" => {
                let count = value.get("count")?.as_u64()?;
                if !(1..=Control::MAXIMUM_REPLAY as u64).contains(&count) {
                    return None;
                }
                Control::Replay(count as u8)
            }
            _ => return None,
        };
        Some(Inbound::Control(control))
    }

    fn encode_control(control: &crate::daemon_control::Control) -> Vec<u8> {
        use crate::daemon_control::Control;
        let value = match control {
            Control::Skip => serde_json::json!({"control": "skip"}),
            Control::SkipAll => serde_json::json!({"control": "skipAll"}),
            Control::Replay(count) => serde_json::json!({"control": "replay", "count": count}),
        };
        serde_json::to_vec(&value).expect("control always serializes")
    }
```

`UnixSocketClient::submit`의 재시도 루프를 `send_payload(&self, payload: &[u8])`로 빼고 두 메서드가 쓴다.

```rust
    pub fn submit(&self, request: &SpeechRequest) -> Result<(), UnixSocketError> {
        self.send_payload(&UnixSocketServer::encode_speech_request(request))
    }

    pub fn send_control(&self, control: &crate::daemon_control::Control) -> Result<(), UnixSocketError> {
        self.send_payload(&UnixSocketServer::encode_control(control))
    }

    fn send_payload(&self, payload: &[u8]) -> Result<(), UnixSocketError> {
        if payload.len() > UnixSocketServer::MAXIMUM_PAYLOAD_BYTES {
            return Err(UnixSocketError::PayloadTooLarge);
        }
        // … 기존 2회 재시도 루프 그대로(payload 참조) …
    }
```

- [ ] **Step 5: 데몬 구현**

`SpeechRequestSource::accept`를 `fn accept(&self) -> Result<crate::daemon_control::Inbound, UnixSocketError>;`로 바꾸고 `run`의 `Ok(request) => { self.submit(request); }`를 교체한다.

```rust
                Ok(Inbound::Speech(request)) => {
                    self.submit(request);
                }
                Ok(Inbound::Control(control)) => self.control(control),
```

`submit` 끝의 워커 생성 블록을 `fn ensure_worker(&self, state: &mut DaemonState)`로 추출하고(`submit`은 `if decision == QueueDecision::Accepted { self.ensure_worker(&mut state); }`), 제어 처리를 추가한다.

```rust
    pub fn control(&self, control: Control) {
        if self.state.lock().unwrap().shutting_down {
            return;
        }
        match control {
            Control::Skip => self.stop_active(),
            Control::SkipAll => {
                self.queue.clear();
                self.stop_active();
            }
            Control::Replay(count) => {
                let items: Vec<SpeechRequest> = {
                    let history = self.history.lock().unwrap();
                    let skip = history.len().saturating_sub(count as usize);
                    history.iter().skip(skip).cloned().collect()
                };
                for item in items {
                    if self.queue.enqueue_replay(item) == QueueDecision::Accepted {
                        let mut state = self.state.lock().unwrap();
                        self.ensure_worker(&mut state);
                    }
                }
            }
        }
    }

    fn stop_active(&self) {
        let mut state = self.state.lock().unwrap();
        if state.active.is_some() {
            state.discard_active = true;
            self.audio.stop();
        }
    }
```

`resident_service.rs`의 두 `impl SpeechRequestSource`(`UnixSocketServer`용, `ServerSource`용)의 `accept` 반환형을 `Result<crate::daemon_control::Inbound, UnixSocketError>`로 바꾼다(본문 `self.accept()`/`self.0.accept()`는 그대로).

- [ ] **Step 6: 통과 확인**

Run: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 전부 통과, 경고 없음.

- [ ] **Step 7: 커밋**

```bash
git add crates/debrief-core/src
git commit -m "feat(daemon): 소켓 제어 명령으로 끊기·비우기·다시 듣기를 처리한다"
```

---

### Task 7: `debrief skip` · `debrief replay` CLI

**Files:**
- Modify: `crates/debrief-core/src/debrief_command.rs` (enum, parse, usage, CliMessages)
- Modify: `crates/debrief/src/main.rs` (`run_command` 분기, `run_control`)

**Interfaces:**
- Consumes: `Control`, `UnixSocketClient::send_control` (6).
- Produces: `DebriefCommand::Skip { all: bool }`, `DebriefCommand::Replay(u8)`, `CliMessages::DAEMON_NOT_RUNNING`, `CliMessages::DAEMON_OUTDATED`.

- [ ] **Step 1: 실패 테스트 작성** — `debrief_command.rs` tests에 추가한다(테스트 헬퍼가 없으면 `fn args(s: &[&str]) -> Vec<String>`를 같이 만든다).

```rust
    #[test]
    fn parses_skip_and_replay() {
        let parse = |a: &[&str]| DebriefCommand::parse(&a.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(parse(&["skip"]), Ok(DebriefCommand::Skip { all: false }));
        assert_eq!(parse(&["skip", "--all"]), Ok(DebriefCommand::Skip { all: true }));
        assert!(parse(&["skip", "--now"]).is_err());
        assert_eq!(parse(&["replay"]), Ok(DebriefCommand::Replay(1)));
        assert_eq!(parse(&["replay", "3"]), Ok(DebriefCommand::Replay(3)));
        assert_eq!(parse(&["replay", "10"]), Ok(DebriefCommand::Replay(10)));
        for bad in [["replay", "0"], ["replay", "11"], ["replay", "x"]] {
            assert!(parse(&bad[..]).is_err(), "{bad:?}");
        }
        assert!(parse(&["replay", "1", "2"]).is_err());
        assert!(DebriefCommand::usage_text().contains("debrief replay [n]"));
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core debrief_command`
Expected: 컴파일 실패 — `no variant Skip`.

- [ ] **Step 3: 구현**

enum에 `Skip { all: bool }`, `Replay(u8)`를 `Dnd` 다음에 추가. `parse`에:

```rust
            "skip" => {
                Self::require_only(tail, &["--all"])?;
                if tail.len() > 1 {
                    return Err(CommandError::Usage("skip accepts only --all".to_string()));
                }
                Ok(DebriefCommand::Skip { all: !tail.is_empty() })
            }
            "replay" => {
                let count = match tail {
                    [] => 1,
                    [value] => value
                        .parse::<u8>()
                        .ok()
                        .filter(|n| (1..=crate::daemon_control::Control::MAXIMUM_REPLAY).contains(n))
                        .ok_or_else(|| CommandError::Usage("replay count must be 1-10".to_string()))?,
                    _ => return Err(CommandError::Usage("replay accepts one count".to_string())),
                };
                Ok(DebriefCommand::Replay(count))
            }
```

`usage_text`의 Controls 블록 끝(`dnd` 줄 다음)에:

```rust
                "  debrief skip [--all]   (stop the current utterance; --all also clears the queue)\n",
                "  debrief replay [n]     (replay the last n utterances, 1-10, default 1)\n\n",
```

(앞의 `dnd` 줄 끝 `\n\n`은 `\n`으로 바꿔 블록을 이어 붙인다.)

`CliMessages`에:

```rust
    pub const DAEMON_NOT_RUNNING: &'static str = "debrief 데몬이 실행 중이 아닙니다. `debrief start`로 시작하세요.";
    pub const DAEMON_OUTDATED: &'static str = "데몬이 이 명령을 지원하지 않습니다. `debrief stop` 후 `debrief start`로 재시작하세요.";
```

`main.rs` `run_command`에 분기를 추가하고 `Control`·`UnixSocketError`를 import한다(`debrief_core`가 re-export하지 않으면 `lib.rs`에 `UnixSocketError` re-export를 추가).

```rust
        DebriefCommand::Skip { all } => run_control(home, if all { Control::SkipAll } else { Control::Skip }),
        DebriefCommand::Replay(count) => run_control(home, Control::Replay(count)),
```

```rust
fn run_control(home: &std::path::Path, control: Control) -> i32 {
    match UnixSocketClient::new(DebriefPaths::for_home(home).socket_url).send_control(&control) {
        Ok(()) => 0,
        // 구버전 데몬은 제어 프레임을 발화로 읽다 실패해 NAK를 돌려준다.
        Err(UnixSocketError::Rejected) => {
            eprintln!("{}", CliMessages::DAEMON_OUTDATED);
            1
        }
        Err(_) => {
            eprintln!("{}", CliMessages::DAEMON_NOT_RUNNING);
            1
        }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace && cargo build --release && ./target/release/debrief replay 0; echo rc=$?`
Expected: 테스트 통과, 마지막 명령은 사용법 오류와 `rc=` 0이 아닌 값.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src crates/debrief/src/main.rs
git commit -m "feat(cli): debrief skip과 debrief replay 명령 추가"
```

---

### Task 8: MCP `speak`의 `intent`와 모드 응답

**Files:**
- Modify: `crates/debrief-core/src/mcp_speak_tool.rs` (`McpSpeakArguments.decision`, `optional_intent`, `execute`)
- Modify: `crates/debrief-core/src/mcp_server.rs` (스키마 `intent`, 성공 응답에 `mode`·`muted`)

**Interfaces:**
- Consumes: `SpeechRequest.decision/cue` (2), `Earcon::Decision` (1).
- Produces: `McpSpeakArguments.decision: bool`; 성공 응답 `{"ok":true,"mode":"<mode>"}` (+ `"muted":true`).

- [ ] **Step 1: 실패 테스트 작성**

`mcp_speak_tool.rs` tests:

```rust
    fn parse(value: serde_json::Value) -> Result<McpSpeakArguments, CommandError> {
        McpSpeakTool::parse_arguments(value.as_object().unwrap())
    }

    #[test]
    fn intent_decision_marks_main_requests_only() {
        let base = serde_json::json!({"text": "x", "voice": "F1", "speed": 1.0, "volume": 1.0, "intent": "decision"});
        assert!(parse(base.clone()).unwrap().decision);
        let mut subagent = base.clone();
        subagent["priority"] = "subagent".into();
        assert!(!parse(subagent).unwrap().decision, "서브에이전트는 결정을 요청하지 않는다");
        let mut bad = base;
        bad["intent"] = "urgent".into();
        assert!(parse(bad).is_err());
    }

    #[test]
    fn decision_request_carries_decision_cue() {
        let home = temporary_home();
        let sink = RecordingSink::new(false);
        let args = McpSpeakArguments { decision: true, ..McpSpeakArguments::new("결정해 주세요".to_string(), "F1".to_string(), 0.93, 0.85) };
        McpSpeakTool::execute(&args, &sink, &crate::diagnostics::Diagnostics::new(&home), None);
        let recorded = sink.recorded();
        assert!(recorded[0].decision);
        assert_eq!(recorded[0].cue, Some(crate::earcon::Earcon::Decision));
        fs::remove_dir_all(&home).ok();
    }
```

`mcp_server.rs` tests — 기존 헬퍼 `NoopSink`, `NoopInstallRunner`, `temporary_home`, `speak_args`를 쓴다.

```rust
    #[test]
    fn speak_schema_has_intent_and_reply_reports_mode() {
        let tool = McpJsonRpc::speak_tool_definition();
        assert_eq!(tool["inputSchema"]["properties"]["intent"]["enum"], json!(["decision"]));

        let home = temporary_home();
        let server = McpServer::new(home.clone(), NoopSink, NoopInstallRunner);
        let result = server.call_tool("speak", &speak_args(None, "main"));
        let reply: Value = serde_json::from_str(&result.message).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["mode"], "normal");
        assert!(reply.get("muted").is_none());

        crate::configuration::DebriefConfiguration { muted: true, ..Default::default() }
            .save(&crate::paths::DebriefPaths::for_home(&home).config_url)
            .unwrap();
        let reply: Value = serde_json::from_str(&server.call_tool("speak", &speak_args(None, "main")).message).unwrap();
        assert_eq!(reply["muted"], true);
        std::fs::remove_dir_all(&home).ok();
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core mcp_`
Expected: 컴파일 실패 — `no field decision`.

- [ ] **Step 3: 구현**

`McpSpeakArguments`에 `pub decision: bool,`(`session` 앞, 주석 `/// 사용자 결정 대기 — main에서만 인정한다.`), `new`에 `decision: false`. `parse_arguments`:

```rust
        let decision = Self::optional_intent(object.get("intent"))? && matches!(priority, SpeechPriority::Main);
        Ok(McpSpeakArguments { text, voice, speed, volume, priority, lane, emotion, decision, session })
```

```rust
    fn optional_intent(value: Option<&Value>) -> Result<bool, CommandError> {
        let Some(value) = value else { return Ok(false) };
        match value.as_str() {
            Some("decision") => Ok(true),
            _ => Err(CommandError::Usage("speak intent must be \"decision\"".to_string())),
        }
    }
```

`execute`의 요청 생성:

```rust
        let request = SpeechRequest {
            envelope,
            priority: arguments.priority,
            lane: arguments.lane,
            emotion: arguments.emotion,
            agent_type: None,
            decision: arguments.decision,
            cue: arguments.decision.then_some(crate::earcon::Earcon::Decision),
            replayed: false,
        };
```

`mcp_server.rs` 스키마 `properties`에 (`session` 다음):

```rust
                    "intent": {
                        "type": "string",
                        "description": "decision: the user must decide or approve before work can continue; plays through quiet/night/companion-off (not mute)",
                        "enum": ["decision"],
                    },
```

`call_tool`의 `speak` 성공 경로에서 `let result = …execute(…)`를 받은 직후 응답을 다시 쓴다(tests는 같은 파일의 하위 모듈이라 private 함수 `speak_tool_definition`·`call_tool`을 그대로 부를 수 있다).

```rust
                    let mut result = result;
                    if !result.is_error {
                        let effective = crate::configuration::DebriefConfiguration::load_effective(
                            &crate::paths::DebriefPaths::for_home(&self.home).config_url,
                            &self.home,
                        );
                        let mut reply = json!({"ok": true, "mode": effective.mode.as_str()});
                        if effective.muted {
                            reply["muted"] = json!(true);
                        }
                        result.message = reply.to_string();
                    }
```

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과. 기존에 `message == "{\"ok\":true}"`를 단정하던 `mcp_server` 테스트가 깨지면 `"ok":true` 포함 검사로 고친다(동작 변경이므로 의도된 수정).

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/mcp_speak_tool.rs crates/debrief-core/src/mcp_server.rs
git commit -m "feat(mcp): speak에 intent=decision을 받고 응답에 유효 모드를 돌려준다"
```

---

### Task 9: 훅 context 모드 지침

**Files:**
- Modify: `crates/debrief-core/src/hook_engine.rs` (`dnd_raised` 필드·빌더, `mode_guidance`, `handle_at`에서 덧붙이기)
- Modify: `crates/debrief-core/src/hook_command_runner.rs` (`load_effective`, `with_dnd_raised`)

**Interfaces:**
- Produces: `HookEngine::with_dnd_raised(self, raised: bool) -> Self`, `HookEngine::mode_guidance(configuration: &DebriefConfiguration, dnd_raised: bool) -> String`.

문구는 UserPromptSubmit context 길이 때문에 spec보다 짧게 쓴다(context-notes에 기록).

| 상태 | 문장 |
|---|---|
| 항상 | `Needs a user decision? pass intent=decision.` |
| focus | `Mode focus: one sentence.` |
| quiet | `Mode quiet: one short sentence, or silence.` / 방해금지면 `Mode quiet (dnd): one short sentence, or silence.` |
| night | `Mode night: speak only with intent=decision.` |
| muted | `debrief muted: do not call speak.` (모드 문장 대신, 결정 안내도 생략) |

- [ ] **Step 1: 실패 테스트 작성** — `hook_engine.rs` tests.

```rust
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
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core hook_engine`
Expected: 컴파일 실패 — `no function mode_guidance`, `with_dnd_raised`.

- [ ] **Step 3: 구현**

`HookEngine`에 `dnd_raised: bool` 필드(`new`에서 `false`)와 빌더:

```rust
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
```

`handle_at`의 시작 계열 분기에서 context를 만든 뒤:

```rust
                let context = if matches!(event.name, HookEventName::SubagentStart) {
                    context
                } else {
                    format!("{context} {}", Self::mode_guidance(&self.configuration, self.dnd_raised))
                };
```

`hook_command_runner.rs`:

```rust
        let stored = DebriefConfiguration::load(&paths.config_url);
        let configuration = DebriefConfiguration::load_effective(&paths.config_url, home);
        let dnd_raised = configuration.mode != stored.mode;
        let session_state = SessionStateStore::new(paths.session_state_url.clone());
        let engine = HookEngine::new(Some(&session_voices)).with_state(&session_state, configuration).with_dnd_raised(dnd_raised);
```

(기존 `let configuration = DebriefConfiguration::load(...)` 줄을 대체한다.)

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과. `voice_catalog.rs:414`의 `< 400` 테스트는 기본 context만 보므로 그대로 통과한다.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src/hook_engine.rs crates/debrief-core/src/hook_command_runner.rs
git commit -m "feat(hook): 시작 계열 context에 유효 모드 지침과 결정 대기 안내를 붙인다"
```

---

### Task 10: 압축 이벤트와 알림 효과음

**Files:**
- Modify: `crates/debrief-core/src/hook_event.rs` (`PreCompact`, `PostCompact`)
- Modify: `crates/debrief-core/src/hook_adapter.rs:45` (subtype 키에 `trigger`)
- Modify: `crates/debrief-core/src/hook_engine.rs` (`notice_for`의 wants·본문·cue)
- Modify: `crates/debrief-core/src/embedded_templates.rs` (`CLAUDE_ONLY_HOOK_EVENTS` 8개, 템플릿 테스트)

**Interfaces:**
- Consumes: `Earcon` (1), `SpeechRequest.cue` (2).
- Produces: `HookEventName::{PreCompact, PostCompact}`, `HookEngine::cue_for(name: HookEventName) -> Option<Earcon>`.

- [ ] **Step 1: 실패 테스트 작성**

`hook_adapter.rs` 기존 `decodes_claude_only_events_with_subtype`의 cases에 추가:

```rust
            (json!({"hook_event_name": "PreCompact", "session_id": "s", "trigger": "auto"}), HookEventName::PreCompact, Some("auto")),
            (json!({"hook_event_name": "PostCompact", "session_id": "s", "trigger": "manual"}), HookEventName::PostCompact, Some("manual")),
```

`hook_engine.rs` tests (기존 `with_subtype` 헬퍼 사용):

```rust
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
```

`embedded_templates.rs` `templates_install_start_hooks_only_and_mcp_meta`의 `claude_only` 배열에 `"PreCompact", "PostCompact"`를 추가한다.

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core hook_ embedded_templates`
Expected: 컴파일 실패 — `no variant PreCompact`.

- [ ] **Step 3: 구현**

`hook_event.rs`: enum·`as_str`·`from_str_value`에 `PreCompact`/`PostCompact`(`"PreCompact"`, `"PostCompact"`)를 추가한다.

`hook_adapter.rs:45`: `subtype: string_in(payload, &["notification_type", "error_type", "trigger"]),`

`embedded_templates.rs`:

```rust
    /// Claude Code에만 있는 이벤트 — 에이전트가 말할 수 없는 순간의 고정 문구 알림과 압축 알림.
    const CLAUDE_ONLY_HOOK_EVENTS: [HookEventName; 8] = [
        HookEventName::StopFailure,
        HookEventName::Notification,
        HookEventName::Elicitation,
        HookEventName::PermissionDenied,
        HookEventName::TeammateIdle,
        HookEventName::TaskCompleted,
        HookEventName::PreCompact,
        HookEventName::PostCompact,
    ];
```

`hook_engine.rs` `notice_for`:

```rust
            HookEventName::PreCompact | HookEventName::PostCompact => event.subtype.as_deref() == Some("auto"),
```

(`wants_notice` match에 추가), 본문 match에:

```rust
            HookEventName::PreCompact => ("컨텍스트를 정리하고 있습니다.".to_string(), SpeechEmotion::Neutral),
            // 압축이 끝나면 말 대신 완료음만 낸다.
            HookEventName::PostCompact => (String::new(), SpeechEmotion::Neutral),
```

텍스트 조립은 효과음 전용이면 레이블을 붙이지 않는다.

```rust
        let text = match label {
            Some(label) if !body.is_empty() => format!("{label}. {body}"),
            _ => body,
        };
```

요청 리터럴의 `cue: None`을 `cue: Self::cue_for(event.name)`로 바꾸고 함수를 추가한다.

```rust
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
```

- [ ] **Step 4: 통과 확인**

Run: `cargo test --workspace`
Expected: 전부 통과. `host_installer`·`diagnostics`의 훅 목록 테스트는 `EmbeddedTemplates::hook_events`를 쓰므로 Claude에 두 이벤트가 생기고 Codex에는 없다. 개별 이벤트 이름을 나열해 단정하는 테스트가 깨지면 두 이름을 Claude 쪽에만 추가한다.

- [ ] **Step 5: 커밋**

```bash
git add crates/debrief-core/src
git commit -m "feat(hook): 자동 압축 알림과 알림별 효과음 추가"
```

---

### Task 11: 스킬·문서 갱신과 최종 검증

**Files:**
- Modify: `crates/debrief-core/src/embedded_templates.rs` (`companion_speak_skill_markdown`의 Args 표·본문)
- Modify: `CLAUDE.md`, `README.md`, `ONBOARDING.md`, `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-10-14-communication-channels/checklist.md`

- [ ] **Step 1: 실패 테스트 작성** — `embedded_templates.rs` 템플릿 테스트 끝에:

```rust
        assert!(skill.contains("intent"), "speak 스킬에 intent 안내가 있어야 한다");
        assert!(skill.contains("debrief replay"));
```

- [ ] **Step 2: 실패 확인**

Run: `cargo test -p debrief-core embedded_templates`
Expected: FAIL — `speak 스킬에 intent 안내가 있어야 한다`.

- [ ] **Step 3: 스킬 문구 구현** — `companion_speak_skill_markdown`:
  - Args 표 `emotion` 행 다음에 `| intent | no | `decision` only: the user must decide or approve before work can continue. Plays through quiet/night/companion-off with a chime; mute still silences it. Main priority only. |\n\`
  - "Work lane:" 문단 앞에 한 문단: `Hooks append the effective mode: focus = one sentence, quiet = one short sentence or silence, night = speak only with intent=decision, muted = do not call speak. Grok has no hooks: the speak reply includes \"mode\" (and \"muted\") — follow it next turn.\n\n\`
  - Controls 줄을 `Controls: \`debrief mute\`, \`debrief mode\`, \`debrief companion\`, \`debrief skip [--all]\`, \`debrief replay [n]\`, \`debrief doctor\`. Binary: \`{executable}\`.`로 바꾼다.

- [ ] **Step 4: 문서 갱신**
  - `CLAUDE.md` 제품 경계: CLI 목록에 `skip` / `replay` 추가. MCP `speak` 인자에 선택 `intent`(`decision`) 추가. 훅 목록의 Claude 전용에 `PreCompact` · `PostCompact`(자동 압축만: 시작 고정 문구, 끝 완료음) 추가. 훅 알림 항목에 효과음(결정·주의·실패·완료, `earcons` 설정, mute로 꺼짐) 한 줄. 턴 브리핑 계약 항목에 "훅 context가 유효 모드 지침을 덧붙이고 `speak` 응답에 `mode`가 온다" 한 줄. 규범 문서 목록에 새 spec 경로 추가. Speech 흐름 블록의 `tools/call speak {…}`에 `intent?` 추가.
  - `README.md`·`ONBOARDING.md` 일상 사용: `debrief replay [n]`, `debrief skip [--all]`, 효과음 끄기(`config.json`의 `"earcons": false`) 설명 추가.
  - `CHANGELOG.md` `[Unreleased]`에 `### 추가` 섹션(기존 `### 제거` 위)으로 5개 기능을 한 줄씩.

- [ ] **Step 5: 전체 검증**

Run: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo build --release`
Expected: 모두 성공.

- [ ] **Step 6: 수동 검증 (사용자와 함께)**

```bash
./target/release/debrief install --repair      # 새 바이너리로 데몬·훅 재배선(데몬 재시작)
./target/release/debrief mode night
# 에이전트 세션에서 intent=decision 발화 1회 → 올라가는 두 음 + 정상 볼륨으로 들리는지
./target/release/debrief mode normal
# 발화 3개가 쌓인 뒤
./target/release/debrief replay 3              # 오래된 순으로 3개
./target/release/debrief skip                  # 재생 중인 것만 끊김, 다음 것 이어짐
./target/release/debrief replay 3 && ./target/release/debrief skip --all   # 전부 멈춤
./target/release/debrief doctor                # hooks.claude.complete 확인
```

자동 압축은 긴 세션에서 발생할 때 "컨텍스트를 정리하고 있습니다."와 완료음을 확인한다. 결과를 context-notes에 남긴다.

- [ ] **Step 7: 커밋**

```bash
git add crates/debrief-core/src/embedded_templates.rs CLAUDE.md README.md ONBOARDING.md CHANGELOG.md docs/superpowers/plans/2026-10-14-communication-channels
git commit -m "docs: 다시 듣기·결정 대기·모드 지침·효과음·압축 알림 문서와 스킬 반영"
```
