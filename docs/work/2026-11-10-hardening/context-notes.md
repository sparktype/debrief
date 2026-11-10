# 하드닝 컨텍스트 노트

## 2026-11-10 시작
- 브랜치 `chore/hardening-2026-11`. 사용자가 추천 6개 전부 진행을 승인.
- 근거: basic-memory `Projects/debrief 상태.md`(소켓 소실 사고 10-19·10-27, 리뷰 Minor 9건 미수정, Supertonic 미러 결정).
- HF 미러 `codeguru76/supertonic-3` 공개 확인, 전체 리비전 `f26b6b0ac3583e5fc3706cb21d70c3c6cfc3f316`.

## 1. 소켓 이전
- 새 경로 `Application Support/debrief/debrief.sock`. `permissions_directory`가 이미 같은 이유로 데이터 디렉터리에 있어 같은 판단을 적용.
- 장수 MCP 프로세스(호스트 세션 동안 유지)는 옛 경로가 컴파일돼 있어, 업그레이드 직후 새 데몬에 못 닿는다 → 옛 경로에 심볼릭 링크(데몬 실행 중에만). 일반 파일·디렉터리는 지우지 않는다.
- pid·last-error.json은 아직 Caches. 소실 사고는 소켓만 기록돼 이번엔 두지 않음(후속 후보).

## 2. 재생 대기
- 기존: 오류 콜백이 비어 있고 Condvar를 무기한 대기 → 재생 중 장치가 끊기면 합성·재생 루프가 묶임.
- cpal 0.18 `ErrorKind` 중 DeviceNotAvailable·StreamInvalidated·HostUnavailable만 치명으로 본다. DeviceChanged는 cpal이 기본 장치로 스트림을 옮기니 계속 재생.
- 오류 없이 조용히 멈추는 경우를 위해 클립 길이 + 3초 상한. 실패는 기존 AudioPlayer의 rebuild 후 1회 재시도 경로를 탄다.
- 실장치 분리 재현은 하지 못함. 대기 로직만 단위 테스트(하드웨어 없이).

## 3. doctor 설치본 불일치
- 버전 문자열 대신 내용(바이트) 비교: `--version` 플래그가 없고 프로세스를 띄우지 않아도 되며, 같은 버전의 개발 빌드 차이도 잡는다. 단점은 버전 번호를 안내하지 못하는 것.
- 같은 파일(canonical 동일)이면 current. 설치본이 없으면 finding 없음.
- 스모크: 개발 빌드로 `doctor`를 돌리면 stale과 함께 `socket.missing`이 나온다(실행 중 0.5.0 데몬은 옛 Caches 소켓). 업그레이드 직후 보게 될 실제 증상이며 복구는 `install --repair`. 사용자의 실제 데몬을 건드리지 않으려고 install은 돌리지 않았다.

## 4. 모델 미러 폴백
- 미러 `codeguru76/supertonic-3` @ f26b6b0a… 는 원본 3cadd1ee와 같은 파일. 크기 4개와 tts.json sha256을 매니페스트와 대조해 일치 확인. 설치 표식(`revision`)은 매니페스트 그대로라 미러로 받아도 표식 비교가 유지된다.
- 이전 결정은 "원본이 사라지면 매니페스트를 미러로 교체"였다. 사용자가 이번에 자동 폴백까지 승인(6개 전부 진행)했고, 신뢰 경계는 sha256 고정이 지킨다.
- 사용자 개인 HF 계정이 배포 바이너리에 박힌다는 점은 사용자에게 알릴 것. 미러가 사라지면 두 번째 후보만 실패하고 원본 경로는 영향 없음.
- 실네트워크 테스트(`DEBRIEF_TEST_NETWORK=1`)로 원본 404 → 미러 성공 확인.

## 5. agent_completed
- 공식 훅 문서(code.claude.com/docs/en/hooks) 매처 표로 확인: `agent_completed` = "A background session finishes or fails. Fires only while agent view is open in a terminal."
- 문서에서 확인하지 못한 것: 같은 백그라운드 세션의 Stop과 겹쳐 발생하는지, payload의 session_id가 어느 세션인지. 겹치면 완료 알림이 두 번 나갈 수 있다 → 실사용 확인 필요.
- 쿨다운 키를 `Notification:agent_completed`로 분리(idle_prompt가 최근에 나가도 완료 알림이 묻히지 않게). 기존 idle_prompt·agent_needs_input 동작은 그대로.
- 훅 배선에 매처가 없어 설치 변경 불필요(모든 Notification 유형이 이미 도달).

## 6. 리뷰 Minor 정리 (부분)
- 원문 9건 목록은 어디에도 없고 basic-memory에 4건 이름만 남아 있다(skip 짧은 창, replay 재시도 중복, 음소거 중 합성, digest에 cue 미포함). 나머지 5건은 식별 불가.
- 수정: ① digest에 cue 포함(효과음만 다른 빈 텍스트 요청이 중복으로 버려짐 — 테스트로 재현) ② 재생 직전에 이미 거부될 발화는 합성하지 않음(기존 테스트가 음소거 중 합성을 전제로 기다려서 단언을 반대로 바꿈 — 테스트 의도는 재생 시점 게이팅이었음).
- 미수정 ③ skip 짧은 창: `queue.next()`가 항목을 꺼낸 뒤 `active`를 세우기 전의 마이크로초 구간에 온 skip이 무시됨. 고치려면 큐 꺼내기와 active 설정을 한 락으로 묶는 구조 변경이 필요하고, 실제 영향은 극히 작아 보류. ④ replay 재시도 중복: 어떤 시나리오인지 메모만으로 특정 불가. `debrief replay`를 연속 두 번 치면 두 번 재생되는 것은 중복 창을 일부러 우회하는 설계 의도.
