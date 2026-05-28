# 코드레벨 개선 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or equivalent disciplined execution. Follow tasks in order and verify each change with tests before moving on.

**Goal:** 2026-05-27 설계 문서 기준으로 코드레벨 개선사항을 우선순위 순서대로 구현한다.

**Reference:** `docs/superpowers/specs/2026-05-27-code-review-improvements-design.md`

---

## Task 1. Grafana false-resolved 방지

**Files**
- Modify: `hook_voice/grafana_poller.py`
- Modify: `tests/test_grafana_poller.py`

- [ ] `PollResult` 또는 동등한 구조화 반환형 추가
- [ ] `poll_once()`가 auth / transient failure / success를 구분하도록 변경
- [ ] fetch 실패 시 snapshot을 갱신하지 않도록 `run()` 수정
- [ ] auth failure는 경고 TTS 1회 후 종료하도록 유지
- [ ] 테스트 추가
  - transient failure 시 resolved 발화가 발생하지 않음
  - auth failure 시 종료
  - success만 snapshot 갱신

**검증**
```bash
.venv/bin/pytest tests/test_grafana_poller.py -q
```

---

## Task 2. Poller testability 개선

**Files**
- Modify: `hook_voice/grafana_poller.py`
- Modify: `tests/test_grafana_poller.py`

- [ ] wait 전략 주입 또는 cycle 분리 설계 반영
- [ ] `run()` 테스트가 실시간 30초 대기를 하지 않도록 수정
- [ ] 느린 테스트를 즉시 종료되는 deterministic test로 교체

**검증**
```bash
time .venv/bin/pytest tests/test_grafana_poller.py -q
```

목표: 기존 대비 유의미한 시간 단축

---

## Task 3. fallback voice/speed 계약 복구

**Files**
- Modify: `hook_voice/player.py`
- Modify: `tests/test_player.py`

- [ ] `say -v <voice>` 경로 구현
- [ ] speed 배율을 macOS WPM으로 환산하는 helper 추가
- [ ] fallback 경로에서도 voice/speed가 유지되도록 수정
- [ ] 테스트 추가
  - macOS say 호출 인자 검증
  - WPM 변환 검증

**검증**
```bash
.venv/bin/pytest tests/test_player.py -q
```

---

## Task 4. transcript 파서 통합

**Files**
- Create: `hook_voice/transcript_parser.py`
- Modify: `hook_voice/hook_handlers.py`
- Modify: `hook_voice/skill_recommender.py`
- Add tests in relevant test files

- [ ] transcript parsing 공용 모듈 추가
- [ ] `handle_hook`, `handle_subagent_stop`, `read_recent_transcripts`가 공용 모듈 사용
- [ ] 서로 다른 transcript 스키마를 정규화하는 테스트 추가

**검증**
```bash
.venv/bin/pytest tests/test_hook_handlers.py tests/test_skill_recommender.py -q
```

---

## Task 5. config/LLM/network 오류 가시화

**Files**
- Modify: `hook_voice/config.py`
- Modify: `hook_voice/llm_client.py`
- Modify: `hook_voice/player.py`
- Add/update tests

- [ ] config validation/normalization 추가
- [ ] LLM client 예외 분류 로깅 추가
- [ ] player fallback 전환 로깅 추가
- [ ] insecure TLS 설정 키 도입 여부 반영

**검증**
```bash
.venv/bin/pytest tests/test_config.py tests/test_llm_client.py tests/test_player.py -q
```

---

## Task 6. 운영 스크립트 정합성 복구

**Files**
- Modify: `server.sh`
- Modify: `hook_voice/last_message.py` if needed

- [ ] `server.sh status`가 실제 last message 파일 경로를 읽도록 수정
- [ ] 파일명 하드코딩 불일치 제거
- [ ] 상태 출력이 정상 동작하는지 수동 검증 절차 문서화

**검증**
```bash
.venv/bin/pytest tests/test_last_message.py -q
```

수동 검증:
```bash
python -m hook_voice history
./server.sh status
```

---

## 최종 검증

- [ ] `tests/` 전체 실행
- [ ] `tts_server/` 전체 실행
- [ ] 변경 로그와 남은 리스크 요약

```bash
.venv/bin/pytest tests/ -q
.venv/bin/pytest tts_server/ -q
```
