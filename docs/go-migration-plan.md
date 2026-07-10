# Chorus → Go 단일 바이너리 전환 계획

작성일: 2026-07-10  
대상: `hook_voice` (Python 패키지) + `tts_server` (FastAPI 서버) → Go 단일 바이너리 `chorus`

---

## 1. 현재 구조 분석

### 1-1. 컴포넌트 구성

| 컴포넌트 | 역할 | 현재 기술 |
|----------|------|-----------|
| `hook_voice` | Claude Code hook 핸들러 — subcommand CLI | Python asyncio |
| `tts_server/server.py` | FastAPI HTTP 서버 (포트 7777) | Python + FastAPI + Pydantic |
| `tts_server/supervisor.py` | uvicorn + TTS Player 루프 통합 관리 | Python asyncio |
| `hooks/*.sh` | Claude Code hook 진입점 (shell → python -m hook_voice) | zsh |
| `supertonic-mlx` | Apple MLX GPU TTS 추론 모델 | Python (외부 라이브러리) |
| `mlx-whisper` | Apple MLX GPU STT 추론 모델 | Python (외부 라이브러리) |

### 1-2. 외부 의존성 분류

#### Python 전용 (Go로 대체 필요)
| 패키지 | 용도 | Go 대안 |
|--------|------|---------|
| `httpx` | 비동기 HTTP 클라이언트 (LLM API) | `net/http` + `resty/resty` |
| `fastapi` | HTTP 서버 프레임워크 | `gin-gonic/gin` or `labstack/echo` |
| `pydantic` | 요청/응답 스키마 검증 | `go-playground/validator` |
| `soundfile` | WAV 파일 읽기/쓰기 | `go-audio/wav` or 순수 Go |
| `numpy` | 오디오 버퍼 (STT 전처리) | `gonum/gonum` or `[]float32` |

#### MLX 추론 전용 (Go에서 호출 불가 — 별도 Python 서비스 유지)
| 패키지 | 용도 | 전략 |
|--------|------|------|
| `supertonic_mlx` | Apple MLX TTS 추론 | **Python 서비스 유지** (포트 7778) |
| `mlx_whisper` | Apple MLX STT 추론 | **Python 서비스 유지** (포트 7778) |
| `sounddevice` | 마이크 스트리밍 | **Python 서비스 유지** |

### 1-3. API 엔드포인트 목록

```
GET  /health
POST /interrupt
GET  /playback/status
GET  /v1/health
POST /v1/tts              ← supertonic-mlx 호출
POST /stt/toggle          ← sounddevice + mlx-whisper
GET  /stt/status
GET  /metrics
GET  /metrics/json
POST /admin/dlq/replay
GET  /admin/dlq
POST /chorus/mute
POST /chorus/mode
POST /chorus/expression
GET  /chorus/setup
POST /chorus/voice
GET  /chorus/hud
```

---

## 2. Go 전환 전략

### 2-1. 아키텍처 결정: 2-프로세스 모델

MLX(Metal GPU) 의존 컴포넌트는 Python 스레드 친화성 제약(단일 워커)으로 인해  
Go에서 직접 구동할 수 없다. **2-프로세스 분리**가 현실적이다.

```
┌─────────────────────────────────────────────────────┐
│  chorus (Go 바이너리, 포트 7777)                      │
│  • CLI subcommand 핸들러 (hook / subagent-stop 등)  │
│  • HTTP 서버 (FastAPI 대체)                          │
│  • TTS Player 루프 (afplay 스풀 소비)                │
│  • LLM 클라이언트 (HMG Hub API)                     │
│  • 우선순위 스풀 (파일 기반)                          │
│  • Circuit Breaker, DLQ, Metrics                   │
│  • HUD 스냅샷, Config 로더                          │
│  • 요약/Retouch 로직 → LLM API 호출                 │
└──────────────┬──────────────────────────────────────┘
               │ HTTP localhost:7778
┌──────────────▼──────────────────────────────────────┐
│  chorus-mlx (Python 서비스, 포트 7778) — 최소화      │
│  • POST /v1/tts  → supertonic_mlx 추론              │
│  • POST /stt/toggle → sounddevice + mlx_whisper    │
│  • GET  /stt/status                                 │
└─────────────────────────────────────────────────────┘
```

**장점**:
- Go 바이너리가 CLI·HTTP·TTS Player·LLM 로직 80%를 담당
- Python은 MLX GPU 바인딩만 (200줄 이하로 최소화)
- hooks/stop.sh → `chorus hook` 직접 호출 (Python 인터프리터 기동 제거 → 50ms 절감)

### 2-2. Go 바이너리 내부 구조

```
cmd/chorus/main.go          진입점 — subcommand 분기
internal/
  config/    config.go      .voice.json 로더
  llm/       client.go      HMG Hub LLM (Gemini/OpenAI 라우팅)
  spool/     priority.go    HIGH/NORMAL/LOW 파일 스풀
  player/    loop.go        afplay 스풀 소비 루프
  tts/       client.go      chorus-mlx HTTP 클라이언트
  summarize/ summarize.go   strip_markdown, chunk_for_tts, has_heavy_code
  router/    voice_router.go voice-map.json 로더
  server/    server.go      HTTP 서버 (gin)
  hud/       snapshot.go    HUD JSON 직렬화
  breaker/   cb.go          Circuit Breaker
  dlq/       dlq.go         Dead Letter Queue
  metrics/   metrics.go     Prometheus exposition
  learning/  stats.go       사용 통계 JSONL
  policy/    policy.go      SpeechPolicy 결정 엔진
  assist/    briefing.go    LLM 브리핑 (Stop hook)
             recommend.go   voiceMode 추천 (PromptSubmit hook)
  hooks/     handlers.go    각 subcommand 구현
```

---

## 3. Go 라이브러리 검토

### 3-1. HTTP 서버

| 후보 | 이유 |
|------|------|
| **`gin-gonic/gin`** (v1.10) | 성숙도·문서·속도 최상. `pydantic` 역할은 `binding` 태그로 대체. middleware 체인이 FastAPI lifespan과 유사. **선택** |
| `labstack/echo` | gin과 유사, slightly lighter. 팀 경험 gin 쪽 더 많음 |

```go
// gin 예시
r := gin.Default()
r.POST("/v1/tts", ttsHandler)
r.GET("/health", healthHandler)
r.Run(":7777")
```

### 3-2. HTTP 클라이언트 (LLM API)

| 후보 | 이유 |
|------|------|
| **표준 `net/http`** | 의존성 없음, context timeout 지원, httpx 대체 가능. **선택** |
| `go-resty/resty` (v2) | 재시도 내장, 가독성 좋음. 필요 시 추가 |

```go
ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
defer cancel()
req, _ := http.NewRequestWithContext(ctx, "POST", url, body)
```

### 3-3. JSON 처리

표준 `encoding/json` + **`tidwall/gjson`** (중첩 JSON 추출 간편).  
Gemini 응답 `candidates[0].content.parts[0].text` 같은 경로 추출에 유용.

```go
text := gjson.Get(body, "candidates.0.content.parts.0.text").String()
```

### 3-4. WAV 파일 처리

| 후보 | 이유 |
|------|------|
| **`youpy/beep` + `go-audio/wav`** | 순수 Go, WAV 인코딩/디코딩. afplay 직접 실행이라 파싱 최소화 |
| 직접 `os.WriteFile` | WAV bytes를 `/tmp/tts-spool/` 에 그냥 저장만 하면 됨 — 현재 구조도 동일 |

현재 Go 바이너리는 WAV를 생성하지 않고 `chorus-mlx`가 내려준 bytes를 파일에 쓰기만 하면 되므로  
**추가 라이브러리 불필요**, 표준 `os` 패키지로 충분.

### 3-5. 설정 파일 (JSON)

표준 `encoding/json` + `struct` 태그.  
Python `dataclass` → Go `struct`, 기본값은 `Default()` 생성자 패턴.

```go
type Config struct {
    AutoSpeak    bool    `json:"autoSpeak"`
    MinChars     int     `json:"minChars"`
    Voice        string  `json:"voice"`
    SummaryModel string  `json:"summaryModel"`
    TtsSpeed     float64 `json:"ttsSpeed"`
    // ...
}

func DefaultConfig() Config {
    return Config{AutoSpeak: true, MinChars: 50, Voice: "Sohee", ...}
}
```

### 3-6. 프로세스 실행 (afplay)

표준 `os/exec`. 현재 supervisor의 `asyncio.create_subprocess_exec` → `exec.CommandContext`.

```go
cmd := exec.CommandContext(ctx, "afplay", "-r", speed, audioPath)
if err := cmd.Start(); err != nil { ... }
```

### 3-7. 파일 시스템 감시 (Spool 폴링)

현재 폴링 방식 유지 (100ms 간격). Go의 goroutine + `time.Ticker` 사용.  
`fsnotify/fsnotify`로 inotify 기반 감시도 가능하나 단순 폴링이 더 예측 가능.

```go
ticker := time.NewTicker(100 * time.Millisecond)
for range ticker.C {
    files, _ := filepath.Glob("/tmp/tts-spool/*.wav")
    if len(files) > 0 { playFile(files[0]) }
}
```

### 3-8. Circuit Breaker

| 후보 | 이유 |
|------|------|
| **`sony/gobreaker`** | 성숙, 단순 API, CLOSED/OPEN/HALF_OPEN 상태 머신 완비. **선택** |
| `rubyist/circuitbreaker` | 오래됨 |

```go
cb := gobreaker.NewCircuitBreaker(gobreaker.Settings{
    Name:        "llm_api",
    MaxRequests: 1,
    Timeout:     30 * time.Second,
    Interval:    10 * time.Second,
    ReadyToTrip: func(c gobreaker.Counts) bool { return c.ConsecutiveFailures >= 3 },
})
result, err := cb.Execute(func() (interface{}, error) { return callLLM() })
```

### 3-9. SQLite (DLQ, 학습 통계)

| 후보 | 이유 |
|------|------|
| **`modernc.org/sqlite`** | CGO 없는 순수 Go SQLite. 단일 바이너리 유지에 필수. **선택** |
| `mattn/go-sqlite3` | CGO 필요 → 크로스 컴파일 복잡 |

```go
db, _ := sql.Open("sqlite", "/tmp/chorus.db")
```

### 3-10. Prometheus 메트릭

| 후보 | 이유 |
|------|------|
| **`prometheus/client_golang`** | 공식, gin 미들웨어 존재. **선택** |

```go
ttsTotal := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "chorus_tts_total"}, []string{"voice"})
```

### 3-11. YAML/JSON 설정 병합

표준 `encoding/json`. `.voice.json`은 JSON만 사용하므로 YAML 불필요.

### 3-12. 로깅

**`uber-go/zap`** — 구조화 로그, 성능 우수. 현재 Python `logging` 모듈 대체.

```go
logger, _ := zap.NewProduction()
defer logger.Sync()
logger.Info("TTS 서버 시작", zap.Int("port", 7777))
```

---

## 4. Python 서비스 최소화 (chorus-mlx)

`tts_server/mlx_service.py` (신규, 200줄 이하):

```python
# chorus-mlx: MLX TTS/STT 전용 마이크로서비스 (포트 7778)
from fastapi import FastAPI
from pydantic import BaseModel
import supertonic_mlx, mlx_whisper, sounddevice as sd

app = FastAPI()

@app.post("/v1/tts")
async def tts(req: TTSRequest) -> Response:
    # MLX 추론 → WAV bytes 반환

@app.post("/stt/toggle")
async def stt_toggle() -> dict:
    # sounddevice 녹음 시작/중지 + mlx_whisper 전사
```

---

## 5. 구현 단계 (체크리스트)

### Phase 1 — 기반 구조 (1~2일)
- [ ] `go mod init github.com/sparktype/chorus`
- [ ] `internal/config` — `.voice.json` 로더, 기본값
- [ ] `internal/spool` — HIGH/NORMAL/LOW 파일 스풀 (priority_spool.go)
- [ ] `internal/player` — afplay goroutine 루프
- [ ] `cmd/chorus/main.go` — subcommand 분기 (cobra or 직접 구현)

### Phase 2 — LLM + TTS 클라이언트 (1일)
- [ ] `internal/llm` — HMG Hub Gemini/OpenAI 라우팅
- [ ] `internal/tts` — chorus-mlx HTTP 클라이언트
- [ ] `internal/breaker` — gobreaker 래핑
- [ ] `internal/summarize` — strip_markdown, chunk_for_tts

### Phase 3 — Hook 핸들러 (2~3일)
- [ ] `internal/hooks/stop.go` — handle_hook (Stop hook)
- [ ] `internal/hooks/subagent_stop.go`
- [ ] `internal/hooks/notification.go`
- [ ] `internal/hooks/prompt_submit.go`
- [ ] `internal/hooks/pre_tool_bash.go`
- [ ] `internal/hooks/post_tool_bash.go`
- [ ] `internal/hooks/session_start.go`

### Phase 4 — HTTP 서버 (1~2일)
- [ ] `internal/server` — gin 라우터, 전체 엔드포인트
- [ ] `/health`, `/interrupt`, `/playback/status`
- [ ] `/chorus/mute`, `/chorus/mode`, `/chorus/hud` 등
- [ ] `internal/metrics` — Prometheus exposition
- [ ] `internal/dlq` — modernc.org/sqlite DLQ

### Phase 5 — Python 서비스 분리 (1일)
- [ ] `tts_server/mlx_service.py` — 200줄 최소 서비스
- [ ] `server.sh` 수정 — chorus 바이너리 + mlx_service.py 각각 기동

### Phase 6 — 검증 (1~2일)
- [ ] `hooks/stop.sh` → `chorus hook` 직접 호출로 변경
- [ ] 전체 기능 smoke test
- [ ] Python .venv 의존성 → mlx_service 전용으로 축소

---

## 6. 빌드 및 설치

```bash
# 빌드
go build -o chorus ./cmd/chorus

# 릴리스 (macOS arm64)
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o chorus ./cmd/chorus

# 설치 (install.sh 연동)
cp chorus /usr/local/bin/chorus
```

`install.sh`의 `$VENV_PY -m hook_voice hook` → `chorus hook` 으로 교체됨.

---

## 7. 기대 효과

| 항목 | 현재 | Go 전환 후 |
|------|------|-----------|
| hook 호출 시 기동 지연 | ~200ms (Python 인터프리터) | ~5ms (Go 바이너리) |
| 메모리 사용 (CLI 호출) | ~40MB (Python) | ~8MB (Go) |
| 배포 방식 | .venv 필요 (수백 MB) | 단일 바이너리 (~15MB) |
| MLX 의존성 | 전체 서버에 포함 | chorus-mlx 격리 |
| 설치 | setup-tts.sh (복잡) | `cp chorus /usr/local/bin` |

---

## 8. 미결 사항 (결정 필요)

1. **CLI 파서**: `spf13/cobra` (표준적) vs 직접 `os.Args` 분기 (현재 Python 방식 유사)  
   → cobra 권장 (서브커맨드·플래그 처리 일관성)

2. **TTS Player goroutine**: supervisor 프로세스와 분리할 것인가  
   → HTTP 서버와 동일 프로세스 내 goroutine으로 통합 (현재 Python supervisor 방식과 동일)

3. **launchd plist**: `server.sh install` 대상이 `chorus` 바이너리로 변경됨  
   → plist에서 `chorus server` 서브커맨드로 기동

4. **chorus-mlx 포트**: 7778로 내부 격리 (외부 노출 불필요)
