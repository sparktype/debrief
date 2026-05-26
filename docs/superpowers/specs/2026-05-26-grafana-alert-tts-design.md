# Grafana Alert → TTS 발화 설계 문서

**날짜**: 2026-05-26  
**상태**: 승인됨  
**오너**: 박상선 책임매니저

---

## 1. 개요

HMG 사내 Grafana에서 발생하는 알럿을 폴링 방식으로 수신하고, LLM으로 분석·요약해 TTS로 발화하는 기능을 summary-voice-mcp에 추가한다.

### 목표

- HMG 사내망 환경에서 방화벽 이슈 없이 동작
- 특정 알럿만 선택해 감시 (configurable)
- Firing 시 LLM 분석 요약 발화, Resolved 시 복구 알림 발화
- 기존 TTS 인프라(speak_hook, spool 직렬화) 변경 없이 재사용

---

## 2. 아키텍처

### 실행 흐름

```
tts_server/supervisor.py
  asyncio.gather(
    player_loop,          ← 기존
    cleanup_loop,         ← 기존
    monitor_children,     ← 기존
    grafana_poll_loop     ← 신규 (GrafanaPoller.run)
  )

GrafanaPoller.run(shutdown):
  while not shutdown:
    alerts = GET /api/alertmanager/grafana/api/v2/alerts
    changes = diff(alerts, previous_snapshot)
    for change in changes:
      if change.status == "firing":
        summary = await analyze_alert(change)   ← LLM 분석
      else:
        summary = f"{change.name} 알럿이 해소되었습니다. {duration}만에 복구됐습니다."
      await speak_hook(summary, config.voice, config.tts_speed)
    previous_snapshot = alerts
    await asyncio.wait_for(shutdown.wait(), timeout=interval)
```

### HMG 사내망 고려사항

- 폴링 방향: Mac → Grafana (아웃바운드 전용, 방화벽 이슈 없음)
- SSL: HMG 인터셉트 프록시로 인해 `httpx.AsyncClient(verify=False)` 사용
- 인증: Grafana Service Account Token (`Authorization: Bearer glsa_xxx`)

---

## 3. 컴포넌트

### 신규 파일

#### `hook_voice/grafana_poller.py`

```python
@dataclass
class AlertChange:
    name: str
    status: Literal["firing", "resolved"]
    labels: dict
    annotations: dict
    value: str
    started_at: datetime
    duration: timedelta | None  # resolved 시 지속 시간

class GrafanaPoller:
    async def poll_once() -> list[AlertChange]
    async def analyze_alert(alert: AlertChange) -> str   # LLM → 요약 텍스트
    async def run(shutdown: asyncio.Event)               # supervisor 진입점
```

**LLM 프롬프트 (Firing 시):**
```
다음 Grafana 알럿 정보를 보고 원인과 대응 방향을 2-3문장으로 요약하세요.
알럿명: {name}
레이블: {labels}
현재값: {value}
설명: {annotations.summary | annotations.description | "(설명 없음)"}
```

**Resolved 처리:** LLM 호출 없이 규칙 기반 템플릿 사용.

### 기존 파일 수정

#### `hook_voice/config.py`

`Config` dataclass에 `grafana` 섹션 추가:

```python
@dataclass
class GrafanaConfig:
    enabled: bool = False
    url: str = ""
    token: str = ""
    interval: int = 30
    alerts: list[str] = field(default_factory=list)

@dataclass
class Config:
    # ... 기존 필드 ...
    grafana: GrafanaConfig = field(default_factory=GrafanaConfig)
```

`.voice-persona.json` 설정 예시:

```json
{
  "grafana": {
    "enabled": true,
    "url": "http://grafana.hmg-internal:3000",
    "token": "glsa_xxx",
    "interval": 30,
    "alerts": ["Kafka Consumer Lag", "Spark Job Failed"]
  }
}
```

#### `tts_server/supervisor.py`

`asyncio.gather()` 호출에 `GrafanaPoller.run(shutdown)` 추가:

```python
from hook_voice.grafana_poller import GrafanaPoller

poller = GrafanaPoller(config)
await asyncio.gather(
    player_loop(shutdown),
    cleanup_loop(shutdown),
    monitor_children(shutdown),
    poller.run(shutdown),         # 신규
)
```

#### `hook_voice/__main__.py`

`grafana` 서브커맨드 추가:

```bash
python -m hook_voice grafana list              # 감시 중인 알럿 목록 출력
python -m hook_voice grafana add "Kafka Lag"  # 알럿 감시 등록
python -m hook_voice grafana remove "Kafka Lag"  # 알럿 감시 해제
python -m hook_voice grafana status           # 폴러 마지막 실행 상태 확인
```

---

## 4. 데이터 흐름

```
grafana_poll_loop
  │
  ├─ GET /api/alertmanager/grafana/api/v2/alerts  (httpx, verify=False)
  │    ↓
  ├─ 감시 목록 필터링 (alerts 이름 교차)
  │    ↓
  ├─ fingerprint 기반 상태 변화 감지
  │    ├─ 신규 Firing → LLM analyze_alert()
  │    └─ Resolved  → 규칙 기반 텍스트
  │         ↓
  └─ speak_hook(text, config.voice, config.tts_speed)
       → /tmp/tts-spool/<ts>.mp3 → afplay 재생
```

---

## 5. 에러 처리

| 상황 | 처리 |
|------|------|
| 네트워크 타임아웃 | 로그 후 다음 사이클 재시도, TTS 없음 |
| 401/403 인증 실패 | 경고 TTS 1회 발화 후 폴러 비활성화 |
| LLM 분석 실패 | 규칙 기반 폴백 `"{name} 알럿이 발생했습니다."` |
| 알럿 burst (3개 초과) | 묶어서 `"N개 알럿이 동시에 발생했습니다."` 요약 발화 |
| supervisor 재시작 | 첫 폴링 사이클은 snapshot만 수집, 발화 없음 (중복 방지) |

---

## 6. 테스트 전략

**파일**: `tests/test_grafana_poller.py`

```
단위 테스트
  ├─ poll_once(): mock httpx → AlertChange 목록 반환 검증
  ├─ analyze_alert(): mock LLM 응답 → 텍스트 반환 / LLM 실패 시 폴백 검증
  ├─ 상태 변화 감지: firing 신규, resolved, 변화 없음 3가지 케이스
  └─ burst: 4개 동시 발화 → 묶음 요약 텍스트 검증

통합 테스트
  ├─ GrafanaPoller.run(): shutdown 이벤트로 정상 종료 검증
  └─ config 필드: `config get grafana.enabled` CLI 동작 검증
```

---

## 7. 구현 순서

1. `hook_voice/config.py` — GrafanaConfig 추가
2. `hook_voice/grafana_poller.py` — GrafanaPoller 구현
3. `tts_server/supervisor.py` — gather에 폴러 편입
4. `hook_voice/__main__.py` — grafana 서브커맨드 추가
5. `hook_voice/hook_handlers.py` — handle_grafana 핸들러 구현
6. `tests/test_grafana_poller.py` — 테스트 작성

---

## 8. 변경 범위 요약

| 파일 | 변경 종류 |
|------|------|
| `hook_voice/grafana_poller.py` | 신규 |
| `hook_voice/config.py` | 수정 (GrafanaConfig 추가) |
| `tts_server/supervisor.py` | 수정 (gather에 1줄 추가) |
| `hook_voice/__main__.py` | 수정 (grafana 서브커맨드) |
| `hook_voice/hook_handlers.py` | 수정 (handle_grafana 추가) |
| `tests/test_grafana_poller.py` | 신규 |
