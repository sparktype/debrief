# Changelog

이 프로젝트의 주요 변경 사항을 버전별로 기록합니다.
형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따릅니다.

## [Unreleased]

## [0.3.2] - 2026-10-18

`brew upgrade sparktype/tap/debrief` 다음 `debrief install`로 적용합니다. huggingface.co가 막힌 망이면 `HF_ENDPOINT=https://<미러> debrief install`을 씁니다.

### 추가

- 모델 다운로드가 `HF_ENDPOINT` 미러를 따릅니다(huggingface.co 호스트만 바꾸고 sha256 검증은 그대로).

### 변경

- `model: DownloadFailed`에 실패한 자산 경로·URL·원인이 붙습니다. 기존 파일 복사 실패도 구분해 보여 줍니다.

## [0.3.1] - 2026-10-18

`brew upgrade sparktype/tap/debrief` 다음 `debrief install`로 새 바이너리를 복사하면 데몬도 다시 올라갑니다. 훅·스킬은 바뀌지 않았습니다.

### 추가

- `debrief restart`: 실행 중이어도 데몬을 내렸다가 다시 올립니다(실행 파일·plist·설정은 그대로).

### 변경

- `debrief status`가 버전과 함께 서비스 상태와 설정 토글을 블릿으로 나눠 보여 줍니다.
- 설치 오류 `Io`에 실패 단계와 원인이 붙습니다(예: `Io("hosts: SettingsRootMustBeObject")`).
- launchctl의 중간 메시지(`Boot-out failed`, 교체 중 첫 `Bootstrap failed: 5`)를 숨깁니다. 결과는 debrief 메시지와 종료 코드로 알립니다.

## [0.3.0] - 2026-10-18

바이너리를 교체한 뒤 `debrief stop` 다음 `debrief start`로 데몬을 재시작하세요. Claude·Codex 훅과 스킬은 바뀌지 않아 `install --repair`가 필요 없습니다. Gemini CLI를 쓰려면 `debrief install --gemini`를 실행합니다.

### 추가

- 새 프롬프트를 보내면 같은 세션의 지난 도우미 브리핑을 자동으로 끊습니다(Claude·Codex·Gemini). 결정 대기, 훅 알림, 다른 세션 발화는 그대로 재생합니다. speak의 `session`이 데몬까지 전달됩니다.
- 발음 사전: `config.json`의 `pronunciations`(예: `{"MCP": "엠씨피"}`)로 합성 직전에 단어 단위로 표기를 바꿉니다. 대소문자는 무시하고 긴 항목이 우선입니다. 다시 듣기 기록은 원문을 유지합니다.
- `debrief mic [on|off|toggle]`(옵트인): 다른 앱이 마이크를 쓰는 동안(통화·회의) 유효 모드를 최소 quiet로 올립니다. 녹음하지 않고 사용 여부만 읽습니다(macOS 14.2+). `doctor`에 `mic.readable`·`mic.unreadable`로 표시됩니다.
- Gemini CLI 호스트(옵트인 `debrief install --gemini`): `~/.gemini/settings.json`에 MCP 서버와 훅(SessionStart·BeforeAgent·AfterAgent·Notification·SessionEnd·PreCompress)을 넣습니다. 이후 플래그 없는 `install --repair`와 `uninstall`에도 포함됩니다. 도구 이름은 `mcp_debrief_speak`입니다.

### 변경

- 45초 넘게 대기한 발화는 재생 차례가 와도 버립니다(결정 대기·다시 듣기 제외).
- 재생 전인 서브에이전트 완료 발화가 겹치면 "서브에이전트 작업 N개가 끝났습니다." 한 줄로 합칩니다. 합쳐진 발화의 개별 문장은 재생되지 않습니다.

## [0.2.3] - 2026-10-18

바이너리만 교체하면 됩니다. `debrief stop` 다음 `debrief start`로 데몬을 재시작하세요.

### 변경

- 효과음을 순수 사인파에서 배음(1·2·3배음)과 지수 감쇠를 더한 벨 음색으로 바꿨습니다. 무선 이어폰이 첫 소리를 삼키는 경우를 줄이려고 앞에 0.08초 무음을 두고, 음 사이에 0.1초 간격을 둡니다. 4종의 리듬을 서로 다르게 했습니다(결정 2음 상승, 주의 1음, 실패 3음 하강, 완료 2음 상승). 근거는 The Sonification Handbook 14장(Table 14.2)입니다.

## [0.2.2] - 2026-10-14

바이너리만 교체하면 됩니다. `debrief stop` 다음 `debrief start`로 데몬을 재시작하세요.

### 변경

- `emotion`이 더 이상 속도를 바꾸지 않습니다. 에이전트가 보낸 `speed`를 그대로 씁니다(청취 결과 감정별 속도 변화보다 모델 기본 속도가 자연스러웠습니다).
- 감정 차이를 쉼과 볼륨으로 키웠습니다. 문장 사이 쉼: focused 0.1초, neutral 0.3초, relieved 0.55초, warm 0.7초, concerned 0.8초, tired 1.1초. 볼륨: tired 0.75배, concerned 1.05배. 표현 태그는 그대로입니다.

## [0.2.1] - 2026-10-14

바이너리만 교체하면 됩니다. 업그레이드 후 `debrief stop` 다음 `debrief start`로 데몬을 재시작하세요. 스킬 문구까지 갱신하려면 `debrief install --repair`를 실행합니다(선택).

### 변경

- 발화를 문장 단위로 합성해, 첫 문장을 재생하는 동안 다음 문장을 합성합니다. 첫 소리까지의 시간이 36~57% 줄었습니다(M1 Max 실측 1.13→0.72초 등).
- 중간 문장 합성이 실패하면 이미 재생한 앞 문장은 그대로 두고 오류만 기록합니다(이전에는 아무것도 재생하지 않음).
- mute·모드 판정은 전체 합성 후가 아니라 첫 문장이 준비된 시점에 합니다.

### 추가

- `emotion`이 문장 사이 쉼(focused 0.2초~tired 0.5초, neutral은 기존 0.3초)과 Supertonic 3 표현 태그(relieved `<laugh>`, warm `<breath>`, tired `<sigh>`)를 줍니다. 에이전트가 쓴 `<` `>`는 지워 태그 주입을 막습니다.
- 훅 context, MCP 도구 설명, speak 스킬에 감정 선택 기준(막히거나 실패하면 concerned, 문제가 풀리면 relieved, 긴 작업 뒤 warm)을 안내합니다.

## [0.2.0] - 2026-10-14

업그레이드 후 `debrief install --repair`(또는 `debrief stop` 후 `debrief start`)로 데몬을 재시작하세요. 재시작 전의 구버전 데몬은 `skip`·`replay`에 "지원하지 않습니다"로 답하고, 자동 압축 완료음 요청을 빈 발화로 받아 합성 오류를 한 번 기록할 수 있습니다.

### 변경

- MCP `speak` 성공 응답이 `{"ok":true}`에서 `{"ok":true,"mode":"<유효 모드>"}`로 바뀌었습니다(음소거면 `"muted":true` 추가). `ok`는 그대로입니다.

### 추가

- `debrief replay [n]`·`debrief skip [--all]`: 최근 재생한 발화(최대 10개, 데몬 메모리)를 다시 듣고, 재생 중인 발화를 끊거나 대기열까지 비웁니다. 데몬 소켓에 제어 명령을 더했습니다.
- MCP `speak`의 `intent: "decision"`: 사용자 결정 대기 발화는 결정 효과음과 함께 quiet·night·도우미 꺼짐에서도 요청 볼륨으로 들립니다(음소거만 막음, main 전용). 대기열에서 일반 main보다 앞섭니다.
- 모드 지침: 시작 계열 훅 context에 유효 모드(방해금지 반영)별 행동 규칙을 덧붙이고, `speak` 응답에 `mode`·`muted`를 돌려줍니다.
- 효과음(`earcons`, 기본 켜짐): 결정·주의(권한·입력 대기·자동 모드 거부)·실패(StopFailure)·완료(긴 턴·TaskCompleted·압축 완료). 코드로 만든 사인파입니다(이후 벨 음색으로 변경, 위 Unreleased 참고).
- Claude `PreCompact`·`PostCompact` 훅: 자동 압축 시작은 "컨텍스트를 정리하고 있습니다.", 끝은 완료음만 냅니다. 수동 `/compact`는 알리지 않습니다.

### 제거

- 로컬 판단 모델 `decide` 연동을 제거합니다. 턴 브리핑 침묵 판단, `emotion: "auto"`, subagent→main 승격, 미등록 `agent_type` 자동 분류, `debrief doctor`의 `decide.reachable`·모드 추천이 사라집니다. 미등록 `agent_type`은 `default` 역할 보이스를 쓰고, `emotion: "auto"`는 이제 인자 오류입니다. 기존 설정의 `decideEnabled` 키는 무시됩니다.

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

[0.2.0]: https://github.com/sparktype/debrief/compare/v0.1.3...v0.2.0
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
