# 소통 채널 확장 설계 — 다시 듣기 · 결정 대기 · 모드 지침 · 효과음 · 압축 알림

상태: 승인(2026-10-14). 대체하는 문서 없음. `2026-10-04-hook-notices-design.md`의 고정 문구 알림
경로와 `2026-07-22-reflective-companion-design.md`의 턴 브리핑 계약을 **유지**하고 그 위에 더한다.
같은 날 제거한 `decide` 연동(침묵 판단·emotion auto·priority 승격)의 역할 일부를, 외부 판단 모델 없이
에이전트의 명시적 표시(`intent`)와 사용자 조작(`skip`·`replay`)으로 대신한다.

## 배경

debrief는 거의 단방향이다. 에이전트가 턴 끝에 말하고, 훅이 몇 순간에 고정 문구를 낸다.

- 사용자는 놓친 발화를 다시 들을 수 없고, 길게 이어지는 발화를 끊을 수 없다.
- 에이전트는 "사용자가 결정해야 진행된다"를 일반 브리핑과 구분해 전할 방법이 없다. night·quiet에서는
  볼륨 상한 때문에 중요한 요청도 작게 들린다.
- 에이전트는 사용자의 현재 모드(방해금지 포함)를 모른다. 음소거 중에도 `speak`를 부른다.
- 소리만으로는 알림 종류를 바로 구분하기 어렵다.
- 자동 컨텍스트 압축 중 에이전트가 멈춘 이유를 알 수 없다.

## 범위 (5개 기능)

| # | 기능 | 방향 | 한 줄 요약 |
|---|------|------|-----------|
| 1 | 다시 듣기 · 끊기 | 사용자 → debrief | `debrief replay [n]` · `debrief skip [--all]` |
| 2 | 결정 대기 의도 | 에이전트 → 사용자 | `speak intent=decision`은 mute 외의 모든 억제를 뚫는다 |
| 3 | 모드 지침 | debrief → 에이전트 | 훅 context에 유효 모드별 행동 규칙, `speak` 응답에 `mode` |
| 4 | 효과음 | debrief → 사용자 | 결정·주의·실패·완료 4종 사인파 톤, 기본 켜짐 |
| 5 | 압축 알림 | 훅 → 사용자 | 자동 `PreCompact` 고정 문구, 자동 `PostCompact` 완료 효과음 (Claude 전용) |

## 제품 경계

- **유지**: STT 없음, debrief 자체 텍스트 생성 없음, 외부 판단 모델 없음, PreToolUse/PostToolUse 미설치,
  `debrief speak` CLI 없음. `mute`는 여전히 **모든** 소리(발화·효과음)를 끈다.
- **허용(신규)**: 데몬 소켓의 제어 명령(`skip`·`skipAll`·`replay`), 코드로 생성하는 효과음,
  Claude `PreCompact`·`PostCompact` 훅.
- Grok은 훅이 없으므로 3은 `speak` 응답으로만, 5는 적용되지 않는다.

## 데이터 모델

### `SpeechRequest`

```rust
pub struct SpeechRequest {
    pub envelope: SpeechEnvelope,
    pub priority: SpeechPriority,
    pub lane: SpeechLane,
    pub emotion: SpeechEmotion,
    pub agent_type: Option<String>,
    pub decision: bool,          // 결정 대기 — ModePolicy가 상한·companion off·subagent 억제를 건너뜀
    pub cue: Option<Earcon>,     // 발화 앞 효과음
}
```

- "들릴지"(`decision`, 정책)와 "무슨 소리를 낼지"(`cue`, 효과음)는 분리한다. MCP가 `decision`을 세우면
  `cue = Some(Decision)`도 함께 세운다.
- **효과음 전용 요청**: `envelope.text`가 비어 있고 `cue`가 있는 요청. 훅만 만든다(PostCompact).
  소비 스레드는 합성을 건너뛰고 효과음만 재생한다. 같은 큐를 타므로 다른 발화와 겹치지 않는다.
  MCP `speak`의 빈 텍스트 거부 규칙(`SpeechEnvelope::validate`)은 바꾸지 않는다.
- 텍스트도 `cue`도 없는 요청은 데몬이 버린다.

### `Earcon`

```rust
pub enum Earcon { Decision, Attention, Failure, Done }
```

| Earcon | 톤 | 사용처 |
|---|---|---|
| Decision | 660Hz → 880Hz, 각 120ms | `speak intent=decision` |
| Attention | 740Hz 150ms | PermissionRequest · Notification · Elicitation · PermissionDenied |
| Failure | 587Hz → 440Hz, 각 140ms | StopFailure |
| Done | 523Hz 100ms | 긴 턴 완료(Stop) · TaskCompleted · 자동 PostCompact |

- 44.1kHz 모노 사인파, 앞뒤 10ms 선형 페이드(클릭 방지). 진폭은 1.0 이하. 오디오 파일을 번들하지 않는다.
- 일반 턴 브리핑 · PreCompact 문구 · TeammateIdle에는 효과음이 없다.

### 제어 명령

```rust
pub enum Control { Skip, SkipAll, Replay(u8) /* 1..=10 */ }
pub enum Inbound { Speech(SpeechRequest), Control(Control) }
```

### 소켓 프레임 (기존 UDS · 4바이트 길이 접두 JSON · ACK 1바이트 유지)

- 발화: 기존 JSON에 선택 필드 `"decision": bool`, `"cue": "decision"|"attention"|"failure"|"done"` 추가.
  없으면 `false` / `None` — 구버전 훅 바이너리와 호환.
- 제어: `{"control": "skip"}` · `{"control": "skipAll"}` · `{"control": "replay", "count": n}`.
  `control` 키가 있으면 제어로 디코딩한다.
- 응답: 성공 `0x06`. 알 수 없는 `control`, `count` 범위(1..=10) 밖은 `0x15`. 클라이언트별 실패이며
  리스너는 계속 돈다(`is_recoverable_accept_error`).

### 설정

- `DebriefConfiguration.earcons: bool` (기본 `true`). 그 외 신규 키 없음. replay 보관 개수 10은 상수.

## 데몬 동작

### 수신 분기

`UnixSocketServer::accept`가 `Inbound`를 돌려준다. `Speech`는 기존 `submit`, `Control`은 `handle_control`.

- `Skip`: 재생 중인 요청이 있으면 `discard_active = true`, `audio.stop()` — main이 subagent를 끊을 때와
  같은 경로. 대기열의 다음 요청은 이어서 재생된다.
- `SkipAll`: `Skip` + `SpeechQueue::clear()`.
- `Replay(n)`: 기록의 최근 n개(기록이 더 적으면 전부)를 **오래된 순**으로 `SpeechQueue::enqueue_replay`에
  넣는다. `enqueue_replay`는 중복 억제 창을 건너뛴다(방금 들은 발화는 창 안이라 일반 enqueue는 거부).
  기록이 비어 있으면 아무것도 하지 않고 ACK.

### 다시 듣기 기록

- 데몬 내부 `Mutex<VecDeque<SpeechRequest>>`, 최대 10개(오래된 것부터 밀어냄). 재시작하면 비워진다.
- **소비 스레드가 재생 시점의 `ModePolicy`를 통과시킨 요청**만 기록한다. 훅 알림 포함.
- 효과음 전용 요청과 replay로 다시 넣은 요청은 기록하지 않는다(중복 적재 방지). 이를 위해 큐 항목에
  `replayed` 표시를 둔다(외부 프레임에는 노출하지 않음).
- PCM은 보관하지 않고 다시 합성한다. 그사이 바뀐 mute·상한이 반영된다.

### 결정 대기 정책

`ModePolicy::admit(priority, lane, volume, configuration, decision)`:

1. `muted` 또는 볼륨이 유한하지 않음 → `None` (기존과 같음).
2. `decision && priority == Main` → `Some(volume.clamp(0, 1))`. companion off · 모드 상한 · subagent 억제를
   건너뛴다.
3. 그 외 → 기존 규칙.

- `decision`은 main에서만 인정한다. MCP가 subagent + `intent=decision`을 받으면 `decision=false`로 내린다
  (서브에이전트는 사용자에게 브리핑하지 않는다는 계약).
- 큐: 결정 대기 요청은 대기 중인 **비결정 main 요청보다 앞**(이미 대기 중인 결정 요청들 뒤)에 넣는다.
  재생 중인 main은 끊지 않고, 재생 중인 subagent는 기존처럼 끊는다.

### 효과음 재생

소비 스레드 순서:

1. 효과음 전용이 아니면 합성한다(실패 시 기존처럼 기록하고 다음 항목).
2. 재생 시점 `ModePolicy`로 `gain`을 구한다. `None`이면 효과음 포함 아무것도 재생하지 않는다.
3. `cue`가 있고 `configuration.earcons`이면 효과음 버퍼를 `gain * 0.6`으로 재생한다. 실패는 무시한다.
4. 발화 버퍼를 `gain`으로 재생한다.

합성을 먼저 끝내므로 효과음과 발화 사이에 공백이 없다. skip으로 `discard_active`가 서면 효과음 뒤
발화도 재생하지 않는다.

## 훅 · MCP · CLI

### 3. 모드 지침

- `HookCommandRunner`가 `DebriefConfiguration::load_effective`로 설정을 읽는다(방해금지 반영, fail-open).
- `SessionStart` · `UserPromptSubmit` context 끝에 덧붙인다(기존 context와 같은 영어):
  - 항상: `If the user must decide or approve before you can continue, pass intent=decision.`
  - 유효 상태별(normal · verbose는 없음):

| 상태 | 문장 |
|---|---|
| focus | `Mode focus: one sentence.` |
| quiet | `Mode quiet: one short sentence; stay silent if nothing new.` 방해금지로 올라간 경우 `Mode quiet (dnd): …` |
| night | `Mode night: speak only with intent=decision; otherwise stay silent.` |
| muted | `debrief is muted: do not call speak.` (모드 문장 대신) |

- `SubagentStart` context는 바꾸지 않는다.
- 방해금지로 올라갔는지 알기 위해 `load_effective`가 쓰는 판정(`with_dnd`)을 그대로 재사용한다.

### 2·3. MCP `speak`

- 선택 인자 `intent`: 스키마 `{"type":"string","enum":["decision"]}`, 설명 "user must decide or approve
  before work can continue; plays through quiet/night/companion-off (not mute)". 그 외 값은 인자 오류.
- 응답: `{"ok":true,"mode":"<유효 모드>"}`, 음소거면 `"muted":true` 추가. 실패 응답은 기존과 같다.
- `debrief-speak` 스킬(전 호스트 공용 템플릿)에 `intent`와 모드 규칙을 반영한다.

### 5. 압축 알림 (Claude 전용)

- `HookEventName::PreCompact` · `PostCompact` 추가. `HookAdapter`의 subtype 키 목록에 `trigger` 추가
  (`manual` | `auto`).
- `PreCompact` + `auto` → 고정 문구 "컨텍스트를 정리하고 있습니다." (`lane=work`, Neutral, 효과음 없음).
- `PostCompact` + `auto` → 효과음 전용 요청(`cue: Done`).
- `manual`이면 둘 다 아무것도 하지 않는다. 쿨다운 없음(드묾). 세션 레이블 규칙은 기존 알림과 같다.
- `HostInstaller`의 Claude 이벤트 목록에 두 이벤트를 추가한다. Codex에는 추가하지 않는다. `doctor`의
  `hooks.claude.missing`은 같은 목록을 쓰므로 자동으로 따라온다.

### 4. 훅 알림 효과음

기존 고정 문구 알림에 위 Earcon 표대로 `cue`를 붙인다. 문구는 바꾸지 않는다.

### 1. CLI

- `debrief skip` / `debrief skip --all` / `debrief replay [n]` (`n` 1..=10, 기본 1, 범위 밖은 사용법 오류).
- `UnixSocketClient::send_control(&Control)` 추가.
- 데몬 없음(연결 실패): "debrief 데몬이 실행 중이 아닙니다. `debrief start`로 시작하세요." 종료 코드 1.
- `0x15` 응답(구버전 데몬이 제어 프레임을 발화로 읽다 실패): "데몬이 이 명령을 지원하지 않습니다.
  `debrief stop` 후 `debrief start`로 재시작하세요." 종료 코드 1.
- 성공 시 출력 없음, 종료 코드 0.

## 오류 처리

- 에이전트 완료를 막지 않는다(기존 원칙). 훅 전송 실패는 기존처럼 `last-error.json`에 기록한다.
- 효과음 생성·재생 실패는 무시하고 발화는 재생한다. 기록하지 않는다.
- 방해금지 판독 실패는 저장된 모드로 폴백(`load_effective` 기존 동작).
- 구버전 클라이언트 → 신버전 데몬: 새 필드 기본값으로 호환. 신버전 CLI → 구버전 데몬: 위 안내 메시지.

## 테스트 (TDD — 기능별 실패 테스트 먼저)

| 단위 | 테스트 |
|---|---|
| `ModePolicy` | decision은 night·quiet 상한과 companion off를 무시, mute에는 막힘, subagent의 decision은 무시 |
| `SpeechQueue` | decision이 대기 중인 비결정 main 앞에 들어감, `clear`, `enqueue_replay`는 중복 창 무시 |
| 소켓 코덱 | 제어 프레임 왕복, 새 필드 없는 구 프레임 디코딩, `count` 0·11에 `0x15` |
| `DebriefDaemon` | skip은 현재만 끊고 다음은 재생, skipAll은 대기열까지 비움, 기록 최대 10개, replay 3은 오래된 순, replay 항목은 기록에 다시 쌓이지 않음, 효과음 전용은 합성 생략, `earcons=false`면 효과음 없음, 효과음 gain은 0.6배 |
| `Earcon` | 종류별 샘플 수, 양 끝 샘플이 0 근처, 진폭 ≤ 1 |
| `HookEngine` | PreCompact auto 문구 · manual 무시, PostCompact auto 효과음 전용, 알림별 cue 매핑 |
| `VoiceCatalog` context | 모드별 문장, muted 문장, decision 안내는 항상 있고 SubagentStart에는 없음 |
| MCP | `intent` 파싱(잘못된 값 오류, subagent면 decision 해제), 응답 `mode`·`muted`, `tools/list`에 `intent` |
| 설치기 | Claude에만 PreCompact·PostCompact 설치, Codex에는 없음 |
| CLI 파싱 | `skip`, `skip --all`, `replay`, `replay 3`, `replay 0`·`replay 11` 오류 |

## 비목표

- 기록 개수 설정, 효과음 종류별 토글, replay 결과 메시지("다시 들을 발화가 없습니다"), PCM 캐시.
- Codex 압축 훅, Grok 훅.
- 음성 입력으로 결정에 답하기, MCP elicitation 음성 처리.

## 검증

- `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release`.
- 수동: 실제 데몬에서 decision 발화와 효과음을 night 모드에서 듣고, 몇 개 발화 후 `replay 3`·`skip`·
  `skip --all` 동작을 귀로 확인한다. 자동 압축 시 문구와 완료음을 확인한다.
