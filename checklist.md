# summary-voice-mcp Phase 1 구현 체크리스트

기준: Delphi 아키텍처 결정 (2026-05-28)
설계 문서: docs/claude_response_design-plan.html

---

## Sprint 1 — 기반 타입 (동작 변경 없음) ✅

- [x] `hook_voice/event/__init__.py` 생성
- [x] `hook_voice/event/canonical.py` — CanonicalEvent, LanguageProfile, Severity, InterruptPolicy
- [x] `hook_voice/adapters/__init__.py` 생성
- [x] `hook_voice/adapters/base.py` — SourceAdapterProtocol (Protocol)
- [x] `hook_voice/speech/__init__.py` 생성
- [x] `hook_voice/speech/pronunciation_db.py` — Trie + LRU 10K + IT 200개 사전
- [x] 테스트: `tests/event/test_canonical.py`
- [x] 테스트: `tests/speech/test_pronunciation_db.py`

## Sprint 2 — 이벤트 파이프라인 ✅

- [x] `hook_voice/event/queue.py` — InMemoryEventQueue (asyncio.PriorityQueue, HWM=800/LWM=200)
- [x] `hook_voice/event/policy.py` — PolicyRules, InMemoryStateStore (asyncio.Lock), PolicyDecisionEngine
- [x] `hook_voice/event/router.py` — EventRouter (JSON 규칙 → handler 매핑)
- [x] `hook_voice/adapters/coding_agent.py` — CodingAgentAdapter
- [x] `hook_voice/adapters/grafana.py` — GrafanaSourceAdapter
- [x] 테스트: `tests/event/test_queue.py`
- [x] 테스트: `tests/event/test_policy.py`
- [x] 테스트: `tests/adapters/test_coding_agent.py`
- [x] 테스트: `tests/adapters/test_grafana.py`

## Sprint 3 — Speech Plugin Chain ✅

- [x] `hook_voice/speech/stages/lang_detect.py`
- [x] `hook_voice/speech/stages/identifier_normalizer.py`
- [x] `hook_voice/speech/stages/pattern_suppressor.py`
- [x] `hook_voice/speech/stages/normalization.py`
- [x] `hook_voice/speech/stages/prosody_boundary.py`
- [x] `hook_voice/speech/stages/ssml_abstraction.py`
- [x] `hook_voice/speech/pipeline.py` — SpeechPipeline (SpeechContext + Stage 체인)
- [x] `hook_voice/hook_handlers.py` 리팩터 — retouch_for_speech → SpeechPipeline 위임
- [x] 테스트: `tests/speech/test_pipeline.py`

## Sprint 4 — Delivery & UX ✅

- [x] `hook_voice/delivery/earcon.py` — 4종 earcon 타입 + 음향 감쇠
- [x] `hook_voice/delivery/priority_spool.py` — priority_score 기반 spool enqueue
- [x] 테스트: `tests/delivery/test_earcon.py`
- [x] 테스트: `tests/delivery/test_priority_spool.py`

## Sprint 5 — 관찰 가능성 ✅

- [x] `hook_voice/observability/otel.py` — 5 spans + no-op 폴백
- [x] `hook_voice/observability/metrics.py` — Prometheus metrics + text exposition
- [x] `hook_voice/observability/dlq.py` — SQLite DLQ (push/replay/stats/purge)
- [x] `tts_server/server.py` 확장 — GET /metrics, GET /metrics/json, GET /admin/dlq, POST /admin/dlq/replay
- [x] 테스트: `tests/observability/test_otel.py`
- [x] 테스트: `tests/observability/test_metrics.py`
- [x] 테스트: `tests/observability/test_dlq.py`

---

## 완료 조건

- [x] 전체 테스트 통과 (305개, 2026-05-28)
- [ ] 기존 hook 동작 보존: stop.sh → handle_hook → TTS 재생 확인
- [ ] Grafana FIRING 이벤트 → earcon + TTS 우선 재생 확인
