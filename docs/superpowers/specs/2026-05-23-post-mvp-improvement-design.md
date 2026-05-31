# chorus MVP 이후 개선 설계

**날짜**: 2026-05-23  
**작성자**: 리드 에이전트 (박상선 책임매니저)  
**상태**: 승인됨

---

## 배경

MVP 기능이 완성된 시점에서 성능, 로직 효율성, 운영 용이성, 배포 용이성 관점으로 코드 전반을 재분석했다. 57개 테스트가 통과하는 안정된 기반 위에서 19개 개선 항목을 도출했다.

---

## 팀 구성

| 에이전트 | 역할 |
|---|---|
| 리드 | cross-layer 선행 처리, 조율, 최종 테스트 검증 |
| TS 팀 | `src/` TypeScript 코드 개선 (8개 항목) |
| Python·Shell 팀 | `tts_server/`, `server.sh` 개선 (8개 항목) |

**실행 순서**: 리드 선행 3건 완료 → TS 팀·Python·Shell 팀 병렬 작업 → 리드 통합 검증

---

## TDD 원칙

모든 항목은 **Red → Green → Refactor** 순서로 진행한다.  
구현 전 실패하는 테스트를 먼저 커밋한다. 기존 57개 테스트는 항상 통과 상태를 유지한다.

---

## 리드 선행 항목 (R1~R3)

두 팀 작업 시작 전 완료해야 한다. 두 팀 모두 이 결과에 의존한다.

### R1 — 포트 설정 이중화 제거 (HIGH)

**문제**: `SirenConfig.supertonicPort`와 `voice-map.json`의 `supertonic.port` 양쪽에 포트 정의. `index.ts`가 voice-map 포트를 사용해 config 설정이 무시됨.

**해결**: `voice-map.json`에서 `supertonic.port` 제거. `index.ts`에서 `config.supertonicPort` 사용. `VoiceMap.supertonic.port` 필드 제거.

**변경 파일**: `src/index.ts`, `voice-map.json`, `src/voice-router.ts`

**테스트**: `config.test.ts` — `loadConfig()`가 `supertonicPort` 반환, voice-map에 port 없어도 동작.

### R2 — `.siren.json.example` 생성 (MEDIUM)

**문제**: `.siren.json`이 `.gitignore`에 있어 팀원 초기 설정 방법 불명확.

**해결**: 모든 `SirenConfig` 키와 기본값을 담은 `.siren.json.example` 파일 생성 및 git 추적.

**변경 파일**: `.siren.json.example` (신규)

**테스트**: 파일 존재 + 모든 `SirenConfig` 키 포함 여부 검증.

### R3 — 버전 정보 단일화 (LOW)

**문제**: `package.json`의 `version`과 `src/index.ts` MCP 서버 version이 각각 수동 관리.

**해결**: `index.ts`에서 `package.json`을 동적 import해 version 참조.

**변경 파일**: `src/index.ts`

**테스트**: MCP 서버 version이 `package.json` 값과 일치 단언.

---

## TS 팀 항목 (T1~T8)

`src/` 디렉토리 내 TypeScript 파일만 수정한다.

### T1 — `makeHubClient()` 싱글톤 (MEDIUM)

**문제**: `extractSummary`·`extractOneLiner` 각각 호출마다 새 OpenAI 인스턴스 생성.

**해결**: `llm-client.ts`에 모듈 수준 싱글톤 인스턴스 도입. 환경변수 변경 시 재생성.

**변경 파일**: `src/llm-client.ts`, `src/summarizer.ts`

**테스트**: `llm-client.test.ts` (신규) — `makeHubClient()` 두 번 호출 시 동일 인스턴스 반환.

### T2 — Transcript 인메모리 캐싱 (MEDIUM)

**문제**: `readRecentTranscripts()`가 hook-suggest 호출마다 파일 stat+read 반복.

**해결**: TTL 60초 인메모리 캐시 도입. 동일 경로 재호출 시 캐시 반환.

**변경 파일**: `src/skill-recommender.ts`

**테스트**: `skill-recommender.test.ts` — 같은 경로 두 번 호출 시 `readFileSync` 1회만 호출.

### T3 — EdgeTTS 타임아웃 config 연동 (LOW)

**문제**: 10s/20s 타임아웃이 코드 상수로 고정. 사내망 지연 환경에서 조정 불가.

**해결**: `SirenConfig`에 `edgeTimeoutMs` (기본 10000), `supertonicTimeoutMs` (기본 20000) 추가.

**변경 파일**: `src/config.ts`, `src/player.ts`

**테스트**: `player.test.ts` — config 값이 실제 abort 타이머에 반영되는지 확인.

### T4 — `EDGE_VOICE_MAP` 단순화 (LOW)

**문제**: 9개 항목 모두 동일한 `ko-KR-HyunsuMultilingualNeural` 값. 불필요한 매핑 테이블.

**해결**: 상수 `EDGE_VOICE = "ko-KR-HyunsuMultilingualNeural"` 하나로 대체. Map 제거.

**변경 파일**: `src/player.ts`

**테스트**: `player.test.ts` — 알 수 없는 voice 입력 시 기본 voice 상수 반환.

### T5 — 빈 segments 방어 코드 (MEDIUM)

**문제**: `generateSupertonic`에서 공백만 입력되면 `segments`가 빈 배열 → `segments[0]?.lang` undefined.

**해결**: segments 빈 배열 시 early return. 호출 전 텍스트 trim 검사 추가.

**변경 파일**: `src/player.ts`

**테스트**: `player.test.ts` — 공백 문자열 입력 시 fetch 미호출 확인.

### T6 — `loadCooldowns()` 이중 호출 제거 (LOW)

**문제**: `recommendSkill`에서 쿨다운 체크 시 `loadCooldowns()` 불필요한 추가 disk read.

**해결**: 함수 상단에서 한 번만 읽어 변수에 저장 후 재사용.

**변경 파일**: `src/skill-recommender.ts`

**테스트**: `skill-recommender.test.ts` — `recommendSkill` 1회 호출 시 cooldown 파일 1회만 읽음.

### T7 — `speakHook`/`speakInner` 폴백 체인 정리 (MEDIUM)

**문제**: `speakHook`이 EdgeTTS → `speakInner` 폴백하는데 `speakInner`도 EdgeTTS 재시도. 이중 시도.

**해결**: `speakInner`에서 EdgeTTS 경로 분리. `speakHook` 폴백 시 HTTP→MLX→say 경로만 사용.

**변경 파일**: `src/player.ts`

**테스트**: `player.test.ts` — `speakHook` Edge 성공 시 `speakInner` 내부 EdgeTTS 미호출 확인.

### T8 — `tts-venv` 경로 동적 탐색 (HIGH)

**문제**: `../tts-venv/bin/python3` 하드코딩. 프로젝트 이동·심볼릭 링크 설치 시 즉시 깨짐.

**해결**: `SIREN_VENV_PYTHON` 환경변수 우선 사용. 미설정 시 `<projectRoot>/tts-venv/bin/python3` → `python3` 순으로 탐색.

**변경 파일**: `src/player.ts`

**테스트**: `player.test.ts` — 환경변수 설정 시 해당 경로 사용, 미설정 시 fallback 경로 사용.

---

## Python·Shell 팀 항목 (P1~P8)

`tts_server/`·`server.sh` 파일만 수정한다.

### P1 — `_TECH_PHONETICS` O(n) → 정규화 Map (LOW)

**문제**: 대소문자 무관 매핑 시 전체 dict 순회. `"DOCKER"`, `"docker"` 각각 처리 불일치.

**해결**: 모듈 로딩 시 `{key.upper(): value}` 정규화 Map 사전 생성. 매칭은 `word.upper()` 조회.

**변경 파일**: `tts_server/server.py`

**테스트**: `pytest` `test_server.py` (신규) — `"docker"`, `"DOCKER"`, `"Docker"` 모두 `"도커"` 반환.

### P2 — TTS Player adaptive sleep (LOW)

**문제**: 스풀 비어있을 때도 0.3초마다 `ls` 실행.

**해결**: 빈 상태 연속 감지 시 sleep 최대 2초까지 지수 증가. 파일 도착 시 즉시 복귀.

**변경 파일**: `tts_server/tts_player.sh`

**테스트**: bash 로직 검증 — 연속 빈 상태에서 sleep 값 증가 확인.

### P3 — 구조화 로그 (MEDIUM)

**문제**: 모든 로그가 plain text. 레벨·타임스탬프 없어 운영 중 필터링 불가.

**해결**: `[INFO]`, `[WARN]`, `[ERROR]` 접두사 + ISO 타임스탬프 형식으로 통일. 로그 함수 헬퍼 도입.

**변경 파일**: `tts_server/server.py`

**테스트**: `pytest` — log 출력이 `[INFO]`/`[ERROR]` 접두사 포함.

### P4 — 스풀 파일 누적 방지 (HIGH)

**문제**: TTS Player 다운 시 `/tmp/tts-spool/` 파일 무한 축적. 재기동 후 오래된 오디오 재생.

**해결**: 데몬 시작 시 5분 초과 오디오 파일 자동 삭제. 스풀 내 파일 최대 10개 초과 시 오래된 것 제거.

**변경 파일**: `tts_server/tts_player.sh`

**테스트**: `pytest` + tmp 디렉토리 픽스처 — 6분 전 파일 시작 시 삭제, 최신 10개만 유지.

### P5 — 모델 로딩 실패 복구 (HIGH)

**문제**: worker thread 예외 시 `_model_ready` 영구 미설정 → `/health` 영구 503 반환.

**해결**: `_model_error` 이벤트·메시지 추가. `/health`에서 error 상태 시 `{"status":"error","detail":"..."}` + 503 반환.

**변경 파일**: `tts_server/server.py`

**테스트**: `pytest` — 로딩 예외 주입 시 `/health` 503 + error detail 반환.

### P6 — Supertonic 상태 확인 포트 방식으로 교체 (MEDIUM)

**문제**: PID 파일 관리 시 좀비 프로세스·PID 재사용 오동작 위험.

**해결**: `_supertonic_running()`을 `lsof -iTCP:${SUPERTONIC_PORT}` 포트 점유 방식으로 교체. `_tts_running()`과 동일 패턴.

**변경 파일**: `server.sh`

**테스트**: bash 스크립트 — 포트 미점유 시 false, 점유 시 true 반환.

### P7 — 헬스체크 중복 제거 (LOW)

**문제**: `curl` 직접 호출이 `do_start`, `do_status`, `do_install` 세 곳에 중복.

**해결**: `_check_health(port)` 공통 함수 추출. 모든 호출부 교체.

**변경 파일**: `server.sh`

**테스트**: 코드 리뷰 — `curl` 직접 호출 패턴이 `_check_health()` 외부에 없음.

### P8 — Supertonic launchd 통합 (MEDIUM)

**문제**: 재부팅 후 TTS 서버는 LaunchAgent 자동 시작, Supertonic은 수동 시작 필요.

**해결**: `server.sh start` 진입점에서 Supertonic 자동 시작 포함. 또는 별도 LaunchAgent 추가.  
채택 방식: `server.sh start`에 Supertonic 시작 로직 통합 (단순성 우선).

**변경 파일**: `server.sh`

**테스트**: bash smoke test — `server.sh start` 후 TTS 서버·Supertonic 둘 다 응답.

---

## 완료 기준

| 기준 | 검증 방법 |
|---|---|
| 기존 테스트 57개 통과 | `npm test` |
| 신규 TS 테스트 통과 | `npm test` |
| 신규 Python 테스트 통과 | `pytest tts_server/` |
| 운영 스크립트 정상 | `server.sh status` 모든 항목 ✓ |
| HIGH 심각도 4건 제거 | R1·T8·P4·P5 코드에서 해소 확인 |

---

## 파일 변경 범위 요약

| 영역 | 변경 파일 |
|---|---|
| TypeScript | `src/config.ts`, `src/index.ts`, `src/llm-client.ts`, `src/player.ts`, `src/skill-recommender.ts`, `src/voice-router.ts` |
| Python | `tts_server/server.py` |
| Shell | `tts_server/tts_player.sh`, `server.sh` |
| 설정·문서 | `voice-map.json`, `.siren.json.example` (신규) |
| 테스트 | `tests/llm-client.test.ts` (신규), `tts_server/test_server.py` (신규), 기존 테스트 파일 보강 |
