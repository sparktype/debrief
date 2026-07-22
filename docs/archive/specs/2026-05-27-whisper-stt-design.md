# Whisper STT 음성 입력 기능 설계

**날짜**: 2026-05-27  
**작성자**: 박상선 책임매니저  
**상태**: 승인됨

---

## 개요

Apple Silicon MLX 가속 Whisper 모델을 TTS Supervisor에 통합하여, 전역 단축키 또는 Claude Code slash 명령으로 마이크 녹음을 시작·중지하고, 변환된 텍스트를 macOS 클립보드를 통해 현재 포커스 위치에 자동 입력한다.

---

## 1. 아키텍처

**방식**: Supervisor 통합 STT 데몬 (Approach A)

- `SpeechListener`를 `tts_server/supervisor.py`의 `asyncio.gather`에 추가
- 기존 `GrafanaPoller`와 동일한 패턴으로 통합
- TTS 서버(`localhost:7777`)에 `/stt/toggle`, `/stt/status` 엔드포인트 추가
- Hammerspoon 또는 Claude Code `/listen` 명령이 HTTP POST로 토글

**선택 이유**: 별도 프로세스 없이 기존 launchd 관리 체계에 편입, 모델을 한 번만 로드하여 메모리 효율성 확보.

### 새 파일 / 수정 파일

| 파일 | 변경 |
|------|------|
| `hook_voice/speech_listener.py` | 신규 — SpeechListener 클래스 |
| `hooks/listen.sh` | 신규 — /stt/toggle curl 래퍼 |
| `tts_server/server.py` | 수정 — `/stt/toggle`, `/stt/status` 엔드포인트 추가 |
| `tts_server/supervisor.py` | 수정 — SpeechListener를 asyncio.gather에 추가 |
| `hook_voice/config.py` | 수정 — 설정 파일명 `.voice.json` 변경 + SttConfig 추가 |
| `.voice-persona.json` | 삭제 → `.voice.json`으로 대체 |
| `.claude/settings.json` | 수정 — `/listen` 명령 등록 |

---

## 2. SpeechListener 클래스

**위치**: `hook_voice/speech_listener.py`

```python
class SpeechListener:
    state: Literal["idle", "recording"]
    _buffer: list[np.ndarray]
    _stream: sounddevice.InputStream
    _lock: asyncio.Lock

    async def toggle() -> dict          # {"state": "recording"|"idle", "text": str|None}
    async def _transcribe(buffer) -> str
    def _type_text(text: str) -> None   # pbcopy → osascript Cmd+V
    async def run(shutdown: asyncio.Event) -> None  # supervisor 진입점
```

**의존성 추가**:
```
mlx-whisper
sounddevice
numpy
```

**텍스트 입력 방식**: clipboard (pbcopy + Cmd+V)
- 특수문자·한글·긴 문자열에서도 안전
- `osascript -e 'tell application "System Events" to keystroke "v" using command down'`

**기본 모델**: `mlx-community/whisper-small-mlx` (244MB, 균형 잡힌 정확도/속도)

---

## 3. 데이터 흐름 및 에러 처리

### 데이터 흐름

```
Hammerspoon / /listen slash 명령
  ↓ HTTP POST localhost:7777/stt/toggle
  ↓
SpeechListener.toggle()
  ├─ idle → recording
  │    sounddevice.InputStream 열기 (16kHz, mono)
  │    _buffer 초기화
  │    (announce=true면) TTS: "녹음 시작합니다"
  │
  └─ recording → idle
       InputStream 닫기
       _buffer → numpy concatenate
       mlx_whisper.transcribe(audio, language="ko")
       텍스트 → pbcopy → osascript Cmd+V
       (announce=true면) TTS: 변환 텍스트 읽기
```

### 에러 처리

| 상황 | 처리 |
|------|------|
| 마이크 없음 / 권한 거부 | `PortAudioError` 캐치 → `error: "no_mic"` 반환, TTS 안내 |
| 1초 미만 짧은 녹음 | 무시 후 idle 복귀, 로그 기록 |
| mlx-whisper 실패 | 로그 기록 + TTS: "변환에 실패했습니다", idle 복귀 |
| osascript 권한 없음 | 시스템 환경설정 접근성 권한 안내 메시지 출력 |
| 서버 미구동 | `listen.sh`에서 HTTP 오류 → stderr 출력 |

**동시성 보호**: `asyncio.Lock`으로 toggle 중복 호출 방지 — 전사 중 두 번째 toggle 무시.

---

## 4. Hammerspoon 설정 + slash 명령

### Hammerspoon (`~/.hammerspoon/init.lua`에 추가)

```lua
-- Whisper STT 토글 (Cmd+Shift+Space)
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  local task = hs.task.new("/usr/bin/curl", nil, {
    "-s", "-X", "POST", "http://localhost:7777/stt/toggle"
  })
  task:start()
end)
```

적용: Hammerspoon 메뉴 → Reload Config (또는 `hs.reload()`).

### Claude Code slash 명령 (`hooks/listen.sh`)

```bash
#!/usr/bin/env bash
# STT 토글 — Claude Code /listen slash 명령에서 호출
curl -s -X POST http://localhost:7777/stt/toggle \
  && echo '{"continue": true}' \
  || echo '{"continue": false, "error": "STT 서버가 응답하지 않습니다"}'
```

`.claude/settings.json` 등록:
```json
{
  "commands": {
    "listen": {
      "description": "음성 입력 토글 (녹음 시작/중지)",
      "command": "hooks/listen.sh"
    }
  }
}
```

---

## 5. 설정 파일 (`.voice.json`)

기존 `.voice-persona.json`을 `.voice.json`으로 이름 변경. 하위 호환을 위해 `config.py`에서 `.voice.json` 우선, `.voice-persona.json` 폴백 순으로 탐색.

```json
{
  "grafana": { "...": "..." },
  "stt": {
    "enabled": true,
    "model": "mlx-community/whisper-small-mlx",
    "language": "ko",
    "sampleRate": 16000,
    "announce": true
  }
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `enabled` | `false` | STT 기능 활성화 여부 |
| `model` | `mlx-community/whisper-small-mlx` | Whisper 모델 경로 |
| `language` | `ko` | 인식 언어 |
| `sampleRate` | `16000` | 마이크 샘플레이트 (Hz) |
| `announce` | `true` | 녹음 시작/완료 TTS 안내 여부 |

---

## 6. 의존성 설치

```bash
.venv/bin/pip install mlx-whisper sounddevice numpy
```

초기 실행 시 모델 자동 다운로드 (~244MB). `HF_HUB_OFFLINE=1` 환경이므로 오프라인 캐시 사용 또는 사전 다운로드 필요:
```bash
HF_HUB_OFFLINE=0 python -c "import mlx_whisper; mlx_whisper.load_models.load_model('mlx-community/whisper-small-mlx')"
```

---

## 7. 테스트 전략

- `SpeechListener.toggle()` — `unittest.mock`으로 `sounddevice`, `mlx_whisper`, `subprocess` mock
- idle→recording→idle 상태 전이 검증
- 짧은 버퍼(1초 미만) 무시 케이스
- `PortAudioError` 에러 처리 경로
- `/stt/toggle`, `/stt/status` FastAPI 엔드포인트 — `httpx.AsyncClient` 통합 테스트
