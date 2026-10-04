# 컨텍스트 노트 — 훅 알림 · 세션 구분 · 방해금지 연동

결정과 이유를 작업하며 아래에 덧붙인다.

## 2026-10-04 시작
- 사용자 요청: 추천 6개 중 1(권한 요청 알림), 4(멀티 세션), 5(긴 작업 완료), 6(방해금지 연동) 구현.
  2(skip), 3(replay)는 제외.
- 브랜치 `feat/hook-notices`는 미병합 브랜치 `worktree-subagent-speak`(서브에이전트 발화 문구 변경) 위에 쌓았다.
- 결정: 알림은 `lane=work`. companion 토글로 권한 알림이 꺼지면 "막혀서 기다리는데 침묵"이 재발하므로.
- 결정: 긴 턴 알림은 에이전트가 이미 말한 턴에는 내지 않는다(중복 방지). 이를 위해 speak가 `spoken`을 표시한다.
- 결정: 방해금지 연동은 옵트인(기본 off). 사용자 소리를 자동으로 줄이는 동작이라서.
- 가정(미검증): 집중 모드 활성 시 `Assertions.json`의 `storeAssertionRecords`가 비어 있지 않다.
  이 머신은 현재 비활성 상태라 활성 구조를 관찰하지 못했다.
- 확인: Codex도 `PermissionRequest`·`Stop` 훅을 지원한다(developers.openai.com/codex/hooks).
- 결정(구현 중): CLI·설정 이름을 `focus`→`dnd`(`dndSync`)로 바꿨다. `debrief mode focus`와 혼동되어서.
- 결정: 훅 엔트리(명령)가 이벤트와 무관하게 동일해서, 과거에 소유한 Stop 항목이 새 Stop 설치와 같은 다이제스트로 합쳐진다.
  그래서 "폐지된 Stop 제거" 테스트를 SubagentStop 기준으로 바꿨다.
- 버그 수정: `begin_turn`이 `last_seen`을 갱신하지 않아 새 항목이 즉시 만료 정리될 수 있었다(운영 경로에선 touch가 앞서 가려짐).
- 보류: `SessionVoiceStore`와 `SessionStateStore`의 잠금 코드가 비슷하다. 기존 코드를 건드리지 않으려고 합치지 않았다.
- 한계: 긴 턴 알림은 에이전트가 `session`을 넘겨 speak를 호출해야 `spoken`이 표시된다(훅이 주입하는 컨텍스트에 session이 들어 있다).

## 2차 (나머지 훅 이벤트)
- 사용자 요청: 추천한 6개 모두 구현. 문서가 잘려 일부 필드명(Claude의 notification_type·error_type·SessionEnd 사유)은
  확인하지 못했다. 결정: 필드가 없으면 침묵하도록 읽는다(잘못된 알림보다 무음이 안전).
- 정정: `stop_hook_active` 기반 Stop 오탐 방지는 효과가 없다고 판단해 구현하지 않았다. `finish_turn`이 한 턴을 한 번만
  마감하기 때문이다. 추천 때 과장해서 말했다.
- 결정: 이벤트 목록을 호스트별로 분리했다. Codex에는 Claude 전용 이벤트를 넣지 않는다(알 수 없는 키가 Codex 설정을 깰 위험).
- 결정: Notification은 idle_prompt·agent_needs_input만. permission_prompt는 PermissionRequest와 중복, elicitation_*는
  Elicitation 훅과 중복이라 제외.
- 결정: 팀 이벤트(TeammateIdle·TaskCompleted)는 잦을 수 있어 `teamNotices` 기본 꺼짐 + 120초 쿨다운. 훅은 항상 설치하고
  런타임에 설정을 읽으므로 켜고 끄는 데 `install --repair`가 필요 없다.
- 테스트 수정: Claude가 Notification 훅을 설치하게 되어 설치기 테스트의 "사용자 무관 훅" 예시를 Notification → PreToolUse로 바꿨다.
- 위험: Codex의 SessionEnd 지원은 문서 요약 기준이다. 실제 Codex가 모르는 이벤트 키를 거부하면 `install --codex --repair` 후 확인 필요.
