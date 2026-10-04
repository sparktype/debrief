# 훅 알림 · 세션 구분 · 방해금지 연동 설계

상태: 제안(2026-10-04). 대체하는 문서 없음. `2026-07-22-reflective-companion-design.md`의
"새 사실도 다음 행동도 없으면 침묵" 계약을 **유지**하되, 아래 두 예외를 추가한다.

## 배경

현재 훅은 컨텍스트만 주입하고 직접 발화하지 않는다(`HookResult.submitted`는 항상 false).
에이전트가 막혀서 사용자를 기다리거나(권한 요청), 오래 걸린 턴이 조용히 끝나도 소리가 없다.
여러 세션을 동시에 쓰면 어느 세션의 목소리인지 구분하기 어렵다. macOS 방해금지 상태는
무시된다.

## 범위 (4개 기능)

| # | 기능 | 한 줄 요약 |
|---|------|-----------|
| 1 | 권한 요청 알림 | `PermissionRequest` 훅이 고정 문구를 데몬에 직접 보낸다 |
| 4 | 멀티 세션 구분 | 다른 프로젝트의 세션이 동시에 활성이면 발화 앞에 프로젝트명을 붙인다 |
| 5 | 긴 턴 완료 알림 | 임계값을 넘긴 턴이 끝났는데 에이전트가 말하지 않았으면 `Stop` 훅이 알린다 |
| 6 | 방해금지 연동 | (옵트인) macOS 방해금지가 켜져 있으면 유효 모드를 최소 `quiet`로 낮춘다 |

## 제품 경계 변경

- **허용**: 훅이 보내는 **고정 문구** 알림(LLM·텍스트 생성 없음). 문구는 코드에 박혀 있다.
- **허용**: `Stop` 훅 설치. 용도는 경과 시간 판단뿐이다. `last_assistant_message`/envelope
  추출은 여전히 **하지 않는다**.
- **유지**: PreToolUse/PostToolUse 미설치, `debrief speak` CLI 없음, STT 없음.
- Grok은 훅이 없으므로 1·5는 적용되지 않는다(4·6은 데몬/MCP 쪽이라 적용).

## 설계

### 공통 — 훅 발화 경로
`HookEngine::handle`이 `HookResult.notice: Option<Notice>`를 돌려주고, `HookCommandRunner`가
`UnixSocketClient`로 데몬에 제출한다. 제출 실패는 기존 진단(`last-error.json`)에 기록하고 호스트에는
항상 `{}`를 돌려준다(에이전트를 막지 않는다).
알림 요청은 `lane=work`, `priority=main`이다. 따라서 `debrief companion off`로는 꺼지지 않고
`mute`로만 꺼진다. 목소리는 그 세션의 도우미 목소리(`SessionVoiceStore.claim`)를 재사용한다.

### 세션 상태 저장소 (`SessionStateStore`)
파일 `session-state.json`, 세션별 `{ project, last_seen, turn_started, spoken }`.
`SessionVoiceStore`와 같은 fcntl 잠금 패턴을 쓰고 24시간 지난 항목과 128개 초과분은 버린다.

### 1. 권한 요청 알림
- `PermissionRequest` → `"{레이블}권한 승인을 기다리고 있습니다."`, emotion `concerned`.
- 연속 요청은 큐의 중복 억제 창이 합친다.

### 5. 긴 턴 완료 알림
- `UserPromptSubmit`: `turn_started = now`, `spoken = false`.
- MCP `speak`(세션 인자 있음): `spoken = true`. 서브에이전트 발화는 표시하지 않는다.
- `Stop`: 경과 ≥ `longTurnSeconds`(기본 60, 0이면 끔) **이고** `spoken == false`이면
  `"{레이블}{N}분 걸린 작업이 끝났습니다."`. 그 외엔 침묵. 항목은 정리한다.
- 에이전트가 이미 브리핑했다면 중복이므로 말하지 않는다.

### 4. 멀티 세션 구분
- 훅이 `cwd`에서 프로젝트 레이블을 뽑아 저장한다(`.claude/worktrees/<n>`이면 그 앞 디렉터리 이름).
- 레이블 규칙: 같은 레이블이 아닌 세션이 최근 30분 안에 `last_seen`이면 활성 다중 세션으로 보고
  speak 본문 앞에 `"{레이블}. "`를 붙인다. 혼자일 때는 붙이지 않는다.
- 설정 `sessionLabel`(기본 true)로 끈다. 알림(1·5)도 같은 규칙을 쓴다.

### 6. 방해금지 연동
- 설정 `dndSync`(기본 **false**, 옵트인). CLI `debrief dnd [on|off|toggle]`. (`debrief mode focus`와 이름이 겹쳐 `focus` 대신 `dnd`를 쓴다.)
- 데몬이 `submit` 때 `~/Library/DoNotDisturb/DB/Assertions.json`을 읽어, `storeAssertionRecords`가
  비어 있지 않은 항목이 있으면 집중 모드 활성으로 본다. 활성이면 유효 모드를
  `Normal|Verbose|Focus → Quiet`로 올린다(`Night`는 그대로). 저장된 모드는 바꾸지 않는다.
- 읽기·파싱 실패는 비활성으로 취급한다(fail-open).
- **미검증**: 집중 모드가 켜진 상태의 실제 파일 구조는 이 개발 머신에서 켜 보지 못했다.
  구현은 알려진 키에 기대며, 사용자가 직접 켜서 확인해야 한다. `dndSync`가 켜져 있으면 `debrief doctor`가 `dnd.readable`/`dnd.unreadable`로 파일 판독 여부를 보여 준다(데몬이 아니라 CLI 프로세스 기준).
  LaunchAgent로 뜬 데몬의 파일 접근 권한(TCC)도 같은 이유로 미검증이다.

## 설치기 변경
`HOOK_EVENTS`: SessionStart, UserPromptSubmit, SubagentStart **+ PermissionRequest, Stop**.
Claude·Codex 모두 두 이벤트를 지원한다. `repair` 시 과거 envelope 시대의 Stop 항목은 다이제스트가
달라 기존 정리 로직으로 처리한다(테스트로 확인).

## 비목표
- 알림음(비언어)·replay·skip·macOS 알림센터 연동은 이번 범위가 아니다.
- 알림 문구 설정화(i18n)는 하지 않는다. 경어체 한국어 고정.

## 검증
`cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release`.
설치 후 수동 확인: 권한 프롬프트 시 소리, 60초 넘는 무발화 턴 종료 시 소리, 집중 모드 켠 채 볼륨.
