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
