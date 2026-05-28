# summary-voice-mcp 코드레벨 개선 설계

**날짜**: 2026-05-27  
**상태**: 제안됨  
**범위**: hook runtime, TTS fallback, transcript parsing, config/LLM observability, testability, 운영 스크립트 정합성

---

## 1. 배경

코드 리뷰 결과, 현재 프로젝트는 기본 기능은 안정적으로 동작하지만 다음 문제가 남아 있다.

1. Grafana 폴링 실패가 잘못된 `resolved` 발화로 이어질 수 있다.
2. macOS `say` fallback 경로가 voice/speed 계약을 지키지 않는다.
3. transcript 파싱 규격이 모듈마다 달라 추천 품질이 흔들린다.
4. 설정/네트워크 오류가 과도하게 삼켜져 운영 원인 파악이 어렵다.
5. 폴링 루프가 실시간 대기 로직과 결합돼 테스트가 비정상적으로 느리다.
6. 운영 스크립트와 런타임 파일명이 일부 불일치한다.

본 문서는 위 항목을 우선순위 순서대로 설계한다.

---

## 2. 목표

- 알럿 발화의 의미적 정확도 보장
- 음성 출력 경로 간 기능 계약 일치
- transcript 기반 기능의 입력 품질 안정화
- 실패 원인 가시성 향상
- 테스트 시간 단축 및 루프 제어 가능성 확보
- 운영 상태 출력 신뢰도 복구

비목표:

- TTS 엔진 전체 교체
- launchd 기반 운영 모델 제거
- Claude hook 인터페이스 자체 변경

---

## 3. 우선순위

### P1. Grafana false-resolved 방지

### P2. fallback voice/speed 계약 복구

### P3. transcript 파서 통합

### P4. config/LLM/network 오류 가시화

### P5. poller testability 개선

### P6. 운영 스크립트 정합성 복구

---

## 4. 상세 설계

### P1. Grafana false-resolved 방지

**문제**

`hook_voice/grafana_poller.py`의 `poll_once()`는 인증 오류 외 모든 예외를 `{}`로 반환한다. `run()`은 이 값을 정상 snapshot으로 간주해 diff를 수행하므로, 일시 네트워크 장애만으로 기존 firing 알럿이 모두 resolved 된 것처럼 발화될 수 있다.

**설계 원칙**

- fetch 실패와 "활성 알럿 0건"을 같은 값으로 표현하지 않는다.
- snapshot 갱신은 성공 fetch에서만 수행한다.
- 인증 실패는 즉시 중지, 일시 실패는 유지 후 재시도한다.

**변경 설계**

신규 상태 타입을 도입한다.

```python
@dataclass
class PollResult:
    ok: bool
    snapshot: dict[str, dict] | None = None
    error_kind: Literal["auth", "network", "decode", "unknown"] | None = None
    error_detail: str = ""
```

`poll_once()`는 `PollResult`를 반환한다.

- 정상: `PollResult(ok=True, snapshot={...})`
- 401/403: `PollResult(ok=False, error_kind="auth")`
- timeout/connect/json parse: `PollResult(ok=False, error_kind="network" | "decode" | "unknown")`

`run()`은 다음 정책을 따른다.

1. `auth` 실패: 경고 TTS 1회 후 loop 종료
2. `ok=False` 이고 `auth` 아님: warning log만 남기고 `prev_snapshot` 유지
3. `ok=True`: 그때만 `_detect_changes(prev_snapshot, snapshot)` 수행 후 `prev_snapshot = snapshot`

**추가 로깅**

- poll cycle 번호
- fetch 성공/실패 여부
- snapshot 크기
- diff 결과 개수

**기대 효과**

- transient failure가 잘못된 resolved 발화로 바뀌지 않음
- 운영자가 "데이터 없음"과 "fetch 실패"를 구분 가능

---

### P2. fallback voice/speed 계약 복구

**문제**

`hook_voice/player.py`의 `_speak_subprocess()`는 MLX speaker가 아니면 `say text`만 호출한다. README의 "`say -v <voice>`로 라우팅" 계약과 다르고, speed도 fallback 경로에 반영되지 않는다.

**설계 원칙**

- 동일한 입력 파라미터는 어떤 출력 경로를 타더라도 의미가 유지돼야 한다.
- voice와 speed는 best-effort가 아니라 공통 계약이어야 한다.

**변경 설계**

`_speak_subprocess(text, voice, speed)`를 경로별로 분리한다.

```python
async def _speak_with_mlx_cli(...)
async def _speak_with_macos_say(text: str, voice: str, speed: float) -> None
```

`_speak_with_macos_say()` 정책:

- `voice`가 비어 있지 않으면 `say -v <voice> <text>`
- 속도는 `say -r <wpm>` 사용
- `speed` 배율을 WPM으로 환산하는 헬퍼 추가
  - 기본 기준 175wpm
  - `1.0 -> 175`, `1.2 -> 210`, `0.9 -> 158`

예시:

```python
def _speed_to_wpm(speed: float) -> int:
    return max(80, min(360, round(175 * speed)))
```

**fallback 선택 규칙**

1. MLX CLI 가능한 speaker면 기존 MLX CLI
2. 아니면 macOS `say -v voice -r wpm`

**기대 효과**

- hook/subagent fallback 모두 voice identity 유지
- README와 코드 계약 일치

---

### P3. transcript 파서 통합

**문제**

`hook_handlers.py`와 `skill_recommender.py`가 서로 다른 transcript 구조를 가정한다. 이로 인해 스킬 추천과 hook 요약이 같은 원본 로그를 다르게 해석할 수 있다.

**설계 원칙**

- transcript 파싱은 단일 모듈에서 수행한다.
- raw json line 스키마 변화에 대응 가능한 정규화 계층을 둔다.

**변경 설계**

신규 모듈 `hook_voice/transcript_parser.py` 추가:

```python
@dataclass
class TranscriptEvent:
    role: Literal["user", "assistant", "tool", "unknown"]
    text: str
    agent_type: str = ""
```

주요 함수:

```python
def parse_jsonl_line(raw: str) -> TranscriptEvent | None
def iter_transcript_events(path: Path) -> Iterator[TranscriptEvent]
def get_last_assistant_text(path: Path, min_length: int = 20) -> str
def get_recent_dialogue(scan_dir: Path, max_files: int, max_lines_per_file: int) -> str
def extract_last_agent_type(path: Path) -> str
```

정규화 규칙:

- `message.role/content`
- top-level `type/content`
- list block 중 `{"type": "text", "text": "..."}`
- tool use block 중 `name == "Agent"`의 `subagent_type`

적용 대상:

- `hook_handlers._extract_last_assistant_text`
- `hook_handlers._extract_agent_type_from_transcript`
- `skill_recommender.read_recent_transcripts`

위 함수들은 삭제 또는 thin wrapper로 축소한다.

**기대 효과**

- hook, subagent, skill 추천이 같은 transcript 해석을 공유
- 로그 포맷이 바뀌어도 수정 지점 단일화

---

### P4. config/LLM/network 오류 가시화

**문제**

현재는 설정 로드 실패, LLM 호출 실패, fallback 전환이 대부분 조용히 무시된다. 장애 시 사용자 체감은 "그냥 음성이 안 남"으로 끝난다.

**설계 원칙**

- 사용자에게 과도한 경고를 하지 않되, 운영 로그에는 충분한 원인을 남긴다.
- fallback은 침묵이 아니라 명시적 상태 전이여야 한다.

**변경 설계**

#### 4-1. config validation 계층 추가

`load_config()` 내부에서 값 정규화/검증 수행:

- `min_chars >= 0`
- `tts_speed > 0`
- `edge_timeout_ms >= 100`
- `supertonic_port` 범위 검증
- `grafana.interval >= 5`

잘못된 값은 기본값으로 교정하고 warning log를 남긴다.

```python
_logger.warning("config key %s invalid (%r), fallback to %r", ...)
```

#### 4-2. llm_client 오류 분류 로깅

`hook_voice/llm_client.py`에서 blanket except 제거 후 최소한 아래를 구분한다.

- timeout
- connect error
- HTTP status error
- invalid response schema

반환값은 계속 `""`를 유지하되, 로그에는 실패 분류를 남긴다.

#### 4-3. player fallback trace 로깅

`player.py`에서 다음 전환 시점 로깅:

- edge generation 실패 → HTTP/server fallback
- supertonic 실패 → generic fallback
- HTTP 429 → subprocess fallback
- macOS say fallback 사용

#### 4-4. TLS 우회 설정의 가시화

현재 `verify=False`와 global SSL monkeypatch를 완전히 제거하지는 않되, 설정 기반으로 명시한다.

신규 config:

```json
{
  "allowInsecureTls": true
}
```

초기 단계에서는 default `true` 유지 가능. 단, 로그에 insecure mode 사용 여부를 남긴다.

**기대 효과**

- silent failure 감소
- 사내망 이슈와 코드 이슈를 로그로 구분 가능

---

### P5. poller testability 개선

**문제**

`GrafanaPoller.run()`이 실시간 `shutdown.wait(timeout=interval)`에 직접 의존해 테스트가 30초씩 지연된다.

**설계 원칙**

- 운영 루프와 시간 제어를 분리한다.
- 테스트는 가상 wait를 주입해 즉시 다음 사이클로 진행할 수 있어야 한다.

**변경 설계**

`GrafanaPoller` 생성자에 wait 전략을 주입 가능하게 한다.

```python
class GrafanaPoller:
    def __init__(
        self,
        config: Config,
        wait_fn: Callable[[asyncio.Event, float], Awaitable[bool]] | None = None,
    ) -> None:
        self._wait_fn = wait_fn or _wait_for_interval
```

기본 구현:

```python
async def _wait_for_interval(shutdown: asyncio.Event, interval: float) -> bool:
    try:
        await asyncio.wait_for(shutdown.wait(), timeout=interval)
        return True
    except asyncio.TimeoutError:
        return False
```

테스트에서는 즉시 반환하는 stub 사용:

```python
async def instant_wait(shutdown, interval):
    return shutdown.is_set()
```

추가로 cycle 로직을 분리한다.

```python
async def run_cycle(prev_snapshot: dict[str, dict]) -> tuple[dict[str, dict], list[AlertChange], bool]:
    ...
```

이렇게 하면 대부분의 테스트는 `run_cycle()` 단위로 검증하고, `run()`은 얇은 orchestration만 남는다.

**기대 효과**

- 느린 테스트 제거
- loop 제어 로직과 diff 로직의 책임 분리

---

### P6. 운영 스크립트 정합성 복구

**문제**

`last_message.txt`와 `last-message.txt`가 혼재해 `server.sh status`의 마지막 발화 표시가 실제로는 비어 있을 수 있다.

**변경 설계**

단일 상수를 기준으로 맞춘다.

- 런타임 기준 파일명은 `last-message.txt` 유지
- `server.sh` 상태 출력도 동일 이름 사용

가능하면 shell에서 하드코딩하지 말고 작은 Python one-liner로 `hook_voice.last_message._get_last_msg_file()` 값을 읽는다.

예시:

```bash
last_msg_file=$("$VENV_PY" - <<'PY'
from hook_voice.last_message import _get_last_msg_file
print(_get_last_msg_file())
PY
)
```

추가 정리 항목:

- hook debug log 경로 상수화
- `hooks/*.sh`의 공통 bootstrap 패턴은 추후 shared shell helper로 통합

**기대 효과**

- `server.sh status` 출력 신뢰도 회복
- 운영자가 마지막 발화를 실제로 확인 가능

---

## 5. 변경 파일 예상

### 신규

- `hook_voice/transcript_parser.py`
- `docs/superpowers/plans/2026-05-27-code-review-improvements.md`

### 수정

- `hook_voice/grafana_poller.py`
- `hook_voice/player.py`
- `hook_voice/hook_handlers.py`
- `hook_voice/skill_recommender.py`
- `hook_voice/config.py`
- `hook_voice/llm_client.py`
- `server.sh`
- 관련 테스트 파일

---

## 6. 테스트 전략

### 단위 테스트

- `poll_once()` 성공/실패/auth failure 결과 타입 검증
- fetch 실패 시 `prev_snapshot` 유지 검증
- `_speed_to_wpm()` 변환 검증
- macOS say subprocess 인자 검증
- transcript parser가 두 스키마를 모두 정규화하는지 검증
- config invalid value normalization 검증

### 통합 테스트

- `GrafanaPoller.run()`이 injected wait로 빠르게 종료되는지 검증
- `handle_hook_suggest()`가 통합 parser 결과를 사용해 추천하는지 검증
- `server.sh status`가 올바른 last message 파일을 읽는지 검증

---

## 7. 구현 순서

1. P1 false-resolved 방지
2. P5 poller testability 개선
3. P2 fallback voice/speed 계약 복구
4. P3 transcript 파서 통합
5. P4 config/LLM/network 오류 가시화
6. P6 운영 스크립트 정합성 복구

P1과 P5는 같은 파일을 다루므로 같은 스프린트에서 묶어 구현한다.

---

## 8. 의사결정

- `poll_once()` 반환형은 dict에서 구조화 타입으로 바꾼다.
- network failure는 state change로 해석하지 않는다.
- transcript parsing은 공용 모듈로 승격한다.
- insecure TLS는 당장 제거하지 않고 설정/로그로 명시한다.
- shell 상태 출력은 Python 런타임 정보와 동일한 파일 경로를 사용한다.
