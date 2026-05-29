# context-notes.md — summary-voice-mcp Phase 1

## 아키텍처 결정 원칙

- **4-Layer Pipeline**: Source Adapter → Event Processing → Speech Preparation → Delivery
- **기존 코드 최대 재사용**: player.py·voice_router.py·config.py·grafana_poller.poll_once() 는 변경 최소화
- **점진적 교체**: 신규 레이어를 먼저 만들고, 기존 핸들러가 위임하도록 연결. 한 번에 다 바꾸지 않음
- **Phase 1 범위 제한**: adapters≤5, EPS≤50, queue_depth<1000. Redis·KEDA·마이크로서비스는 Phase 2

## 중요 설계 결정

### CanonicalEvent
- 17개 필드, frozen=False (mutable — 파이프라인에서 단계별 보강)
- `priority_score` 0–100: Grafana FIRING critical=90, SubagentStop=30
- `interrupt_policy`: ALWAYS(Grafana critical) / QUEUE(일반) / DISCARD(바쁠 때 낮은 우선순위)
- `fingerprint`는 PolicyStateStore 중복 제거 키

### Event Queue
- `asyncio.PriorityQueue` 기반, (-priority_score, timestamp) 튜플로 정렬
- HWM=800 도달 시 DISCARD 정책 이벤트부터 버림
- LWM=200 복구 시 정상 수신 재개

### Speech Pipeline
- 8단계 DAG (Phase 1: 선형 실행)
- `retouch_for_speech()` LLM 호출 제거 → pronunciation_dict + normalization 단계로 대체
- LLM은 extract_summary / extract_one_liner 에만 사용 (요약 목적)
- expression tag 선택 (select_expression_tag)은 ssml_abstraction 단계로 이동

### Earcon
- 파일 기반 (WAV 사전 생성) or pydub 인메모리 생성
- spool 최앞단에 삽입 (priority_score += 100으로 TTS보다 항상 먼저)
- 음향 감쇠: 배열 내 2번째 음=85%, 3번째 음=70%

### PolicyStateStore
- asyncio.Lock + dict로 구현 (Phase 1 단일 루프 가정)
- dedupe_key 기반 중복 감지, TTL 기반 만료

### DLQ
- SQLite 파일: `~/.local/share/voice-persona/dlq.db`
- 컬럼: id, event_id, idempotency_key, failure_stage, error_detail, created_at, replay_status
- failure_stage: "ingest_parse" / "adapter_transform" / "router_dispatch" / "queue_enqueue" / "sink_delivery"
- Phase 1: 수동 재시도만 (POST /admin/dlq/replay)

## 파일별 핵심 노트

### hook_handlers.py (리팩터 대상)
- handle_hook: raw 파싱 → CodingAgentAdapter → EventQueue publish → consume → SpeechPipeline → speak_hook
- handle_subagent_stop: 동일 패턴, voice/label 정보는 CanonicalEvent.metadata에 포함
- 리팩터 후에도 `async def handle_hook(raw, config)` 시그니처 유지 (테스트 호환)

### summarizer.py (부분 리팩터)
- retouch_for_speech() 제거 — SpeechPipeline의 pronunciation_dict + normalization 단계가 대체
- extract_summary(), extract_one_liner(), select_expression_tag(), sanitize_for_speech() 유지
- 단, select_expression_tag 로직은 ssml_abstraction.py로 복사 이전 후 summarizer.py에서는 그대로 사용 (호환성)

### grafana_poller.py (부분 리팩터)
- poll_once() 그대로 유지
- run() 루프는 GrafanaSourceAdapter.run()으로 이전
- GrafanaPoller 클래스는 유지 (어댑터가 내부에서 생성해 사용)

### pronunciation_db.py (신규)
- Trie: 접두사 매칭 (itsdangerous, GPU 등 복합 용어)
- LRU 캐시: maxsize=10000, key=(언어, 원문)
- IT 200개 초기 사전 예시:
  - API → 에이피아이, GPU → 지피유, HTTP → 에이치티티피, LLM → 엘엘엠
  - CLI → 씨엘아이, SDK → 에스디케이, TTS → 티티에스, STT → 에스티티
  - YAML → 야믈, JSON → 제이슨, REST → 레스트, gRPC → 지알피씨
  - CI/CD → 씨아이씨디, PR → 피알, OTel → 오텔, ...

## 테스트 격리 전략
- 신규 event/ adapters/ speech/ delivery/ observability/ 모듈은 mock 의존 없이 순수 단위 테스트
- hook_handlers.py 통합 테스트는 기존 방식 유지 (AsyncMock speak_hook)
- SQLite DLQ 테스트는 pytest tmp_path fixture 사용
- OTel 테스트는 opentelemetry-sdk의 InMemorySpanExporter 사용

## 주의사항
- HMG 사내 SSL 프록시: httpx는 verify=False, edge_tts는 _SSL_CTX 패치 — 신규 모듈도 동일 패턴 적용
- asyncio_mode = auto (pytest-asyncio) — 모든 async 테스트에 자동 적용
- Supertonic voice ID (F1~F5, M1~M5)는 voice-map.json에서만 관리, 코드 하드코딩 금지
