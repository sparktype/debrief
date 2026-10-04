# Changelog

이 프로젝트의 주요 변경 사항을 버전별로 기록합니다.
형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따릅니다.

## [Unreleased]

### 수정

- `debrief install`이 Codex/Grok `config.toml`의 debrief 블록에서 설치 경로(`command`)만 달라진 경우를 고치지 못하고 사용자 수정으로 보존만 하던 문제. 이전에 debrief가 설치한 기록이 있고 `command` 줄을 빼면 우리 조각과 같다면 낡은 경로로 보고 복구합니다. BEGIN 마커만 사라진 블록도 같은 조건에서 제자리에서 복구합니다. 다른 값을 직접 바꾼 블록과 설치 기록이 없는 외부 `debrief` 테이블은 이전처럼 보존합니다. 이 문제로 `debrief doctor`가 권하는 `install --codex --repair`가 `mcp.codex.stalePath`를 고치지 못했습니다.

## [0.1.3] - 2026-10-04

업그레이드 후 `debrief install --repair`를 한 번 실행해야 새 훅이 호스트 설정에 들어갑니다. `debrief doctor`가 누락된 이벤트를 알려 줍니다.

### 추가

- 훅 고정 문구 알림. 에이전트가 말할 수 없는 순간에 훅이 데몬으로 짧은 문구를 직접 보냅니다(LLM 생성 없음, `lane=work`, `mute`로만 꺼짐). 권한 요청, API 오류로 중단(StopFailure), 입력 대기(Notification `idle_prompt`·`agent_needs_input`, Elicitation), 자동 모드의 도구 호출 거부(PermissionDenied), 에이전트가 말하지 않은 `longTurnSeconds`(기본 60초) 이상 걸린 턴의 완료가 대상입니다. 잦은 유형에는 2~5분 쿨다운이 있습니다.
- 에이전트 팀 알림(TeammateIdle·TaskCompleted). `teamNotices`를 켠 경우에만 동작합니다(기본 꺼짐).
- 멀티 세션 구분. 다른 프로젝트 세션이 30분 안에 활성이면 발화 앞에 프로젝트 이름을 붙입니다(`sessionLabel`, 기본 켜짐). 워크트리 경로는 원래 프로젝트 이름을 씁니다.
- macOS 방해금지 연동 `debrief dnd [on|off|toggle]`(옵트인, 기본 꺼짐). 방해금지가 켜지면 유효 모드를 최소 quiet로 올립니다(night은 유지, 저장된 모드는 그대로).
- `debrief doctor`에 `hooks.<host>.missing`/`complete`(호스트별 훅 이벤트 누락 점검)와 `dnd.readable`/`dnd.unreadable`을 추가했습니다.

### 변경

- 서브에이전트는 사용자에게 브리핑하지 않지만, 작업이 끝나면 `priority=subagent`, `lane=work`로 사실 한 줄을 한 번 말합니다(focus/quiet/night에서는 억제).
- 설치하는 훅 이벤트가 늘었고 호스트별로 나뉩니다. 공통은 SessionStart, UserPromptSubmit, SubagentStart, PermissionRequest, Stop, SessionEnd이고, Claude에는 StopFailure, Notification, Elicitation, PermissionDenied, TeammateIdle, TaskCompleted가 더해집니다. Stop은 완료 알림 판단에만 쓰며 문장 추출은 하지 않습니다.
- 세션 상태(프로젝트·턴 시작·발화 여부)를 `session-state.json`에 보관하고 SessionEnd에서 정리합니다.

### 알려진 한계

- Claude 훅 문서가 일부 잘려 `notification_type`·`error_type` 필드명은 확인하지 못했습니다. 필드가 없으면 해당 알림은 나가지 않습니다(침묵).
- 방해금지가 켜진 상태의 `Assertions.json` 구조는 이 개발 환경에서 직접 관찰하지 못했습니다.

## [0.1.2] - 2026-10-02

### 추가

- 선택적 로컬 판단 모델 `decide`(`jev-style serve`, `http://127.0.0.1:8765`) 연동. 텍스트를 생성하지 않고 확률/선택만 반환하는 보강 전용이며, `decide` 불가·타임아웃·연결 끊김 시 전부 기존 동작으로 즉시 폴백합니다(fail-open). `DebriefConfiguration.decideEnabled`/`decideEndpoint`로 토글(기본 활성화).
  - 미등록 서브에이전트 `agent_type`을 9개 역할 카테고리 중 하나로 자동 분류(정적 매핑에 없을 때만 호출).
  - MCP `speak`의 main+companion 턴 브리핑에 침묵 판단(보고 가치가 낮으면 전송하지 않음)을 추가.
  - `emotion: "auto"` 요청 시 decide가 6개 emotion 중 하나를 선택.
  - subagent priority 사실을 decide가 중요하다고 판단하면 main으로 승격.
  - `debrief doctor`에 `decide.reachable` 상태와 참고용 모드 추천(자동 적용 없음)을 추가.

## [0.1.1] - 2026-10-01

### 수정

- 한국어 합성이 영어 음소에 가깝게 들리던 심각한 버그. Rust 재작성의 유니코드 정규화(NFKD)가 빈 스텁으로 남아 있어, 완성형 한글 음절(가/각/나 등)을 `unicode_indexer.json`이 아는 분해된 자모(초성/중성/종성)로 바꾸지 못했습니다. 그 결과 모든 한글 음절이 무효 토큰(-1)으로 인코딩되어 모델이 음소 정보 없이 추론했습니다. `unicode-normalization` 크레이트로 실제 NFKD 분해를 적용했습니다.

## [0.1.0] - 2026-10-01

### 변경

- Swift 단일 바이너리 구현을 Rust Cargo 워크스페이스(`debrief-core`, `debrief-tts`, `debrief`)로 전면 재작성했습니다. Swift Testing의 모든 테스트 케이스를 1:1로 포팅해 183개 Rust 테스트가 통과하며, 실제 설치된 Supertonic 3 모델로 한국어 합성·재생까지 수동 검증했습니다. ONNX 추론은 `ort` 크레이트, 오디오 재생은 `cpal`을 씁니다. 배포는 Homebrew가 소스를 빌드하지 않고 GitHub Release의 프리빌트 바이너리를 받습니다.
- `debrief install --claude`가 Claude Code MCP를 `~/.claude/settings.json`이 아니라 `~/.claude.json`에 등록합니다. Claude Code는 사용자 범위 MCP 서버를 `~/.claude.json`에서만 읽으므로, 이전 설치가 `settings.json`에 남긴 등록은 더 이상 작동하지 않았습니다. 설치 시 낡은 항목을 자동 이전합니다.

### 수정

- 발화 제출의 ACK 대기 타임아웃을 150ms에서 2초로 늘렸습니다. 서버가 부하로 느릴 때 짧은 타임아웃으로 재시도하면 같은 발화가 두 번 재생될 수 있었습니다.

## [0.0.6] - 2026-09-30

### 추가

- 코드 오너십 안내. 코드를 작성·수정·분석한 턴에서는 턴 브리핑의 "다음 행동"이 사용자가 직접 확인해야 할 핵심(동작 변경, 삭제, 보안·데이터 경로, 에이전트의 가정, 확인·되돌리기 방법)이 되어 인지 부채를 줄입니다. 훅 컨텍스트, `debrief-speak` 스킬, `speak` 도구 설명에 문구를 추가했으며 새 도구나 호출은 없습니다. 사소한 변경과 서브에이전트는 제외하고, 에이전트의 준수는 코드로 강제하지 않습니다.

### 수정

- 추적에서 제외된 `.agents/plugins/marketplace.json`을 읽어 실패하던 `RepositoryCutoverTests`.

## [0.0.5] - 2026-09-30

### 수정

- 0.0.4의 BTM 쓰로틀 회피가 불완전했던 부분. `install`이 `bootstrap` 호출은 건너뛰어도 LaunchAgent plist 파일 자체는 내용이 같아도 매번 다시 썼는데, 파일을 다시 쓰기만 해도 mtime이 바뀌어 macOS Background Task Management가 그 로그인 항목을 재스캔합니다. 반복하면 여전히 BTM의 알림 속도 제한에 걸릴 수 있었습니다. plist 내용이 실제로 바뀌지 않았으면 파일 쓰기 자체를 건너뛰도록 고쳤습니다.

## [0.0.4] - 2026-09-30

### 수정

- `debrief install`을 짧은 시간 안에 반복 실행하면 `launchctl bootstrap`이 `5: Input/output error`로 실패하던 문제. 원인은 launchd 자체가 아니라 macOS Background Task Management(BTM)의 알림 속도 제한(`Exceeded max notifications`)이었습니다 — `install`이 매번 무조건 LaunchAgent를 `bootout` → `bootstrap`으로 재등록했는데, 이 재등록마다 BTM이 로그인 항목을 다시 스캔하고, 짧은 간격으로 반복되면 BTM 스스로 알림을 제한하며 그 상태에서 `bootstrap`이 EIO로 실패했습니다. 실행 파일과 LaunchAgent plist 내용이 이전 설치와 동일하고 데몬이 이미 정상 동작 중이면 재등록 자체를 건너뛰도록 고쳤습니다.

## [0.0.3] - 2026-09-30

### 변경

- 소스 전반에 남아 있던 이전 제품명 `Chorus` 식별자를 `Debrief`로 통일했습니다 (모듈명 `ChorusCore`/`ChorusCLI` → `DebriefCore`/`DebriefCLI`, 타입명 `ChorusPaths`/`ChorusCommand`/`ChorusConfiguration`/`ChorusDaemon`/`ChorusMode`/`ChorusVersion` 등). 사용자 노출 동작 변경은 없습니다.
- `Chorus`·`prompt-recap`이라는 이전 제품명으로 설치된 잔재를 청소하던 레거시 마이그레이션 로직을 제거했습니다. 더 이상 그 이름으로 설치된 사용자가 없고, 리터럴이 현재 `Debrief` 식별자와 겹치는 채로 남아 있으면 오히려 현재 설치를 구버전으로 오인해 지울 위험이 있었습니다.

### 수정

- 리포지토리 소스 루트처럼 우연히 `debrief`라는 이름의 파일이나 디렉터리가 있는 위치에서 `debrief install`을 실행하면 `No such file or directory`로 실패하던 문제. 원인은 실행 파일 자기 경로를 `argv[0]`에서 구했는데, 쉘이 `PATH` 탐색으로 커맨드를 찾아 실행할 때 `argv[0]`은 절대경로가 아니라 사용자가 입력한 문자열 그대로 전달되기 때문입니다. `_NSGetExecutablePath`로 항상 정확한 절대경로를 구하도록 고쳤습니다.

## [0.0.2] - 2026-09-30

### 추가

- 도우미(companion) 목소리가 세션마다 F1–M5 여섯 종 사이를 순환합니다. 같은 세션 ID는 항상 같은 목소리를 유지합니다.
- 코드 리뷰 서브에이전트에는 전용 목소리(M2)를 배정했습니다.
- Homebrew 설치(`sparktype/tap/debrief`)를 정식 설치 경로로 문서화했습니다.

## [0.0.1] - 2026-09-29

### 추가

- Codex·Claude Code·Grok용 로컬 TTS 전용 macOS Apple Silicon 서비스 최초 릴리스.
- 단일 Swift 실행 파일이 Supertonic 3 모델 설치, 헤드리스 `LaunchAgent`, MCP `speak`/`install`, 호스트별 시작 훅·스킬 배선을 전부 담당합니다.
- Homebrew 설치: `brew install sparktype/tap/chorus`, 이후 `chorus install` (0.0.2부터 `debrief`로 개명).

[0.1.3]: https://github.com/sparktype/debrief/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/sparktype/debrief/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/sparktype/debrief/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sparktype/debrief/compare/v0.0.6...v0.1.0
[0.0.6]: https://github.com/sparktype/debrief/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/sparktype/debrief/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/sparktype/debrief/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/sparktype/debrief/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/sparktype/debrief/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/sparktype/debrief/releases/tag/v0.0.1
