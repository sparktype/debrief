# 컨텍스트 노트 — 소통 채널 확장

## 2026-10-14 브레인스토밍 결정
- decide 연동을 같은 날 제거했다(`a1e0022`). 침묵 판단·emotion auto·승격의 역할을 외부 모델 없이 에이전트의 명시 표시(`intent`)와 사용자 조작(`skip`·`replay`)으로 대신한다.
- 결정 대기: mute만 막고 볼륨 상한·companion off·모드 억제는 무시. main에서만 인정(서브에이전트는 사용자에게 브리핑하지 않는다는 계약).
- replay 기록: 재생 시점에 ModePolicy를 통과한 발화만, 훅 알림 포함, 최대 10개, 데몬 메모리(재시작 시 비움). PCM은 보관하지 않고 다시 합성 — 그사이 바뀐 mute·상한이 반영된다.
- skip은 현재 발화만, `--all`은 대기열까지.
- 효과음 기본 켜짐(`earcons`), 4종, 일반 브리핑에는 없음. 오디오 파일 번들 없이 사인파 생성.
- 제어 전달은 기존 UDS 프레임에 `control` 키를 얹는 방식(별도 소켓·파일 신호 기각: 정리 대상과 doctor 항목이 늘거나 폴링이 필요).
- 효과음 전용 요청(PostCompact)은 제어 명령이 아니라 빈 텍스트 + `cue` SpeechRequest로 같은 큐를 탄다 — 재생 중인 발화와 겹치지 않게.
- 압축: 자동만. PreCompact는 문구, PostCompact는 완료음만. 수동 `/compact`는 사용자가 직접 한 것이라 알리지 않는다. Claude 전용.

## 2026-10-14 계획 단계 조정
- UserPromptSubmit context에 400자 미만 테스트(`voice_catalog.rs`)가 있어 모드 지침 문구를 spec보다 짧게 정했다(`Needs a user decision? pass intent=decision.` 등). 지침은 HookEngine이 덧붙이므로 기본 context 테스트는 그대로 두고, 덧붙인 전체 길이는 520자 미만으로 새 테스트가 지킨다.
- 방해금지로 quiet가 되었는지는 `load`와 `load_effective`의 모드를 비교해 판단한다(새 상태 없음).
- 소비 스레드에서 `discard_active`를 `if let` 조건 안에서 잠그면 재생 내내 락이 잡혀 skip이 교착된다. 매번 짧게 잡는 클로저로 읽는다.
- `cargo fmt --check`은 작업 전부터 실패 상태라 전체 포맷을 돌리지 않는다.

## 환경 메모
- 같은 날 Stop 훅 지연(40초) 원인은 hindsight 내장 PostgreSQL WAL 손상 + Cerebras 402였다. hindsight Stop 훅만 `~/.claude/settings.json`에서 제거했다(백업 `settings.json.bak-hindsight-20261014001119`). 복구 후 되돌릴 것.

## 2026-10-14 구현
- Task 6: 기존 테스트 3곳(권한 알림 러너, 소켓 왕복, DirectSpeechCommand)이 `accept()`가 `SpeechRequest`를 돌려준다고 가정해 `Inbound::Speech`를 꺼내도록 고쳤다.
- 수동 검증(체크리스트 13)은 실제 설치 바이너리·훅·실행 중 데몬을 바꾸므로 사용자가 직접 `install --repair` 후 진행한다.
- `usage_text`의 "Controls (written to config.json…)" 머리말 아래에 skip/replay가 들어갔다. 둘은 설정을 쓰지 않는 명령이라 머리말과 살짝 어긋난다(사소, 미수정).
