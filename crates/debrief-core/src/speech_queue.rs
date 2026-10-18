// 발화 요청 큐 — main 우선순위 선점, 중복 억제, 용량 초과 시 서브에이전트 축출
//
// Swift 원본은 actor + CheckedContinuation으로 대기자를 깨우지만, 이 재작성은 동기(std)
// 전용이므로(설계 문서의 동시성 모델 참고) Mutex + Condvar로 같은 동작을 구현한다.
use crate::speech_envelope::SpeechEnvelope;
use crate::speech_request::SpeechRequest;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueDecision {
    Accepted,
    RejectedDuplicate,
    RejectedCapacity,
}

struct QueueState {
    pending: VecDeque<SpeechRequest>,
    recent_digests: Vec<([u8; 32], Instant)>,
}

pub struct SpeechQueue {
    capacity: usize,
    duplicate_window: Duration,
    state: Mutex<QueueState>,
    condvar: Condvar,
}

impl SpeechQueue {
    pub fn new(capacity: usize, duplicate_window: Duration) -> Self {
        assert!(capacity > 0, "queue capacity must be positive");
        SpeechQueue {
            capacity,
            duplicate_window,
            state: Mutex::new(QueueState { pending: VecDeque::new(), recent_digests: Vec::new() }),
            condvar: Condvar::new(),
        }
    }

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

    pub fn remove_where(&self, predicate: impl Fn(&SpeechRequest) -> bool) {
        self.state.lock().unwrap().pending.retain(|pending| !predicate(pending));
    }

    fn insert(&self, state: &mut QueueState, request: SpeechRequest) -> QueueDecision {
        if request.is_main() {
            state.pending.retain(|pending| pending.is_main());
        }
        // replay는 사용자가 고른 과거 묶음이다. 용량으로 최신 항목을 잃지 않게 상한을 건너뛰고(최대 10개),
        // 결정 대기라도 새치기하지 않아 오래된 순서를 지킨다. 재생 정책의 decision은 그대로 둔다.
        let is_decision = request.decision && request.is_main() && !request.replayed;

        if !request.replayed && state.pending.len() >= self.capacity {
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

    pub fn next(&self) -> SpeechRequest {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(request) = state.pending.pop_front() {
                return request;
            }
            state = self.condvar.wait(state).unwrap();
        }
    }

    pub fn should_interrupt_active(active: &SpeechRequest, incoming: &SpeechRequest) -> bool {
        incoming.is_main() && !active.is_main()
    }

    pub fn pending_texts(&self) -> Vec<String> {
        self.state.lock().unwrap().pending.iter().map(|request| request.envelope.text.clone()).collect()
    }

    fn digest(envelope: &SpeechEnvelope) -> [u8; 32] {
        // Swift sorts JSON keys before hashing; serde_json's default Map (no
        // `preserve_order` feature) is a BTreeMap, so round-tripping through
        // `Value` yields the same sorted-key byte representation.
        let value = serde_json::json!({
            "v": envelope.v,
            "text": envelope.text,
            "voice": envelope.voice,
            "speed": envelope.speed,
            "volume": envelope.volume,
        });
        let data = serde_json::to_vec(&value).expect("envelope always serializes");
        let mut hasher = Sha256::new();
        hasher.update(&data);
        hasher.finalize().into()
    }
}

impl Default for SpeechQueue {
    fn default() -> Self {
        Self::new(8, Duration::from_secs(3))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speech_request::SpeechPriority;

    fn request(priority: SpeechPriority, text: &str) -> SpeechRequest {
        SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: text.to_string(), voice: "F1".to_string(), speed: 0.93, volume: 0.6 },
            priority,
            lane: crate::speech_lane::SpeechLane::Companion,
            emotion: crate::speech_emotion::SpeechEmotion::Neutral,
            agent_type: if matches!(priority, SpeechPriority::Subagent) { Some("explore".to_string()) } else { None },
            decision: false,
            cue: None,
            replayed: false,
            session: None,
        }
    }

    #[test]
    fn main_evicts_queued_subagents() {
        let queue = SpeechQueue::new(8, Duration::from_secs(3));
        queue.enqueue(request(SpeechPriority::Subagent, "one"));
        queue.enqueue(request(SpeechPriority::Subagent, "two"));
        queue.enqueue(request(SpeechPriority::Main, "done"));

        assert_eq!(queue.pending_texts(), vec!["done".to_string()]);
    }

    #[test]
    fn main_interrupts_only_active_subagent() {
        assert!(SpeechQueue::should_interrupt_active(&request(SpeechPriority::Subagent, "x"), &request(SpeechPriority::Main, "y")));
        assert!(!SpeechQueue::should_interrupt_active(&request(SpeechPriority::Main, "x"), &request(SpeechPriority::Main, "y")));
        assert!(!SpeechQueue::should_interrupt_active(&request(SpeechPriority::Subagent, "x"), &request(SpeechPriority::Subagent, "y")));
    }

    #[test]
    fn full_queue_evicts_oldest_subagent_but_rejects_when_all_main() {
        let mixed = SpeechQueue::new(3, Duration::ZERO);
        mixed.enqueue(request(SpeechPriority::Main, "main"));
        mixed.enqueue(request(SpeechPriority::Subagent, "oldest"));
        mixed.enqueue(request(SpeechPriority::Subagent, "newer"));

        assert_eq!(mixed.enqueue(request(SpeechPriority::Subagent, "incoming")), QueueDecision::Accepted);
        assert_eq!(mixed.pending_texts(), vec!["main".to_string(), "newer".to_string(), "incoming".to_string()]);

        let main_only = SpeechQueue::new(2, Duration::ZERO);
        main_only.enqueue(request(SpeechPriority::Main, "one"));
        main_only.enqueue(request(SpeechPriority::Main, "two"));

        assert_eq!(main_only.enqueue(request(SpeechPriority::Subagent, "rejected")), QueueDecision::RejectedCapacity);
        assert_eq!(main_only.pending_texts(), vec!["one".to_string(), "two".to_string()]);
    }

    #[test]
    fn duplicate_envelope_is_suppressed_only_inside_window() {
        let queue = SpeechQueue::new(8, Duration::from_millis(10));
        let duplicate = request(SpeechPriority::Subagent, "same");

        assert_eq!(queue.enqueue(duplicate.clone()), QueueDecision::Accepted);
        assert_eq!(queue.enqueue(duplicate.clone()), QueueDecision::RejectedDuplicate);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(queue.enqueue(duplicate), QueueDecision::Accepted);
    }

    #[test]
    fn next_resumes_after_capacity_rejection() {
        let queue = std::sync::Arc::new(SpeechQueue::new(1, Duration::ZERO));
        queue.enqueue(request(SpeechPriority::Main, "kept"));
        assert_eq!(queue.enqueue(request(SpeechPriority::Subagent, "rejected")), QueueDecision::RejectedCapacity);

        let first = queue.next();
        assert_eq!(first.envelope.text, "kept");

        let waiting_queue = queue.clone();
        let waiting = std::thread::spawn(move || waiting_queue.next());
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(queue.enqueue(request(SpeechPriority::Subagent, "continued")), QueueDecision::Accepted);
        assert_eq!(waiting.join().unwrap().envelope.text, "continued");
    }

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

    #[test]
    fn replay_bypasses_capacity_and_keeps_oldest_first_order() {
        let queue = SpeechQueue::new(2, Duration::ZERO);
        queue.enqueue(request(SpeechPriority::Main, "live-1"));
        queue.enqueue(request(SpeechPriority::Main, "live-2"));
        assert_eq!(queue.enqueue_replay(decision("old-decision")), QueueDecision::Accepted);
        assert_eq!(queue.enqueue_replay(request(SpeechPriority::Main, "old-plain")), QueueDecision::Accepted);
        assert_eq!(queue.pending_texts(), vec!["live-1", "live-2", "old-decision", "old-plain"]);
    }
}
