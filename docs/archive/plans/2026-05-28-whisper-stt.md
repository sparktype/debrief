# Whisper STT 음성 입력 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mlx-whisper로 마이크 입력을 받아 Whisper STT 전사 후 macOS 클립보드 붙여넣기로 현재 포커스 입력창에 자동 입력하는 기능을 추가한다.

**Architecture:** SpeechListener 클래스를 `hook_voice/speech_listener.py`에 구현하고, FastAPI 서버(`tts_server/server.py`)의 lifespan에서 초기화한다. Hammerspoon 단축키 또는 Claude Code `/listen` 명령이 `POST /stt/toggle` 을 호출하면 idle↔recording 상태가 전환되며, recording→idle 전환 시 mlx-whisper로 전사 후 pbcopy+osascript로 텍스트를 입력창에 주입한다.

**Tech Stack:** mlx-whisper, sounddevice, numpy, FastAPI, asyncio, subprocess(pbcopy, osascript), Hammerspoon

---

## 파일 구조

| 파일 | 변경 | 역할 |
|------|------|------|
| `hook_voice/config.py` | 수정 | SttConfig 추가, `.voice.json` 우선 탐색, `.voice-persona.json` 폴백 |
| `hook_voice/speech_listener.py` | 신규 | SpeechListener 클래스 (idle↔recording 상태 기계, 전사, 텍스트 주입) |
| `tts_server/server.py` | 수정 | `/stt/toggle` POST, `/stt/status` GET 엔드포인트, lifespan에 SpeechListener 초기화 |
| `hooks/listen.sh` | 신규 | `/stt/toggle` curl 래퍼 — Claude Code slash 명령 |
| `.gitignore` | 수정 | `.voice.json` 추가 |
| `.voice-persona.json` | 삭제→이름변경 | `.voice.json`으로 대체 |
| `tests/test_config.py` | 수정 | SttConfig 파싱 테스트 추가 |
| `tests/test_speech_listener.py` | 신규 | SpeechListener 상태 기계 + 에러 처리 테스트 |

---

## Task 1: 의존성 설치 + 설정 파일 이름 변경

**Files:**
- Modify: `.gitignore`
- Rename: `.voice-persona.json` → `.voice.json`

- [ ] **Step 1: 의존성 설치**

```bash
.venv/bin/pip install mlx-whisper sounddevice numpy
```

Expected: `Successfully installed mlx-whisper-...` 메시지 (또는 already satisfied).

- [ ] **Step 2: 모델 사전 다운로드 (HF_HUB_OFFLINE 임시 해제)**

```bash
HF_HUB_OFFLINE=0 .venv/bin/python -c "
import mlx_whisper
mlx_whisper.transcribe.__module__  # 임포트 확인
# 모델 캐시 다운로드
import subprocess
subprocess.run([
    '.venv/bin/python', '-c',
    'from mlx_whisper.load_models import load_model; load_model(\"mlx-community/whisper-small-mlx\")'
], check=True)
"
```

Expected: `Fetching ...` 메시지와 함께 `~/.cache/huggingface/hub/` 에 모델 저장 (~244MB).

- [ ] **Step 3: `.gitignore`에 `.voice.json` 추가**

현재 `.gitignore` 파일에서 `.voice-persona.json` 줄 다음에 `.voice.json` 추가:

```
.voice-persona.json
.voice.json
```

- [ ] **Step 4: 설정 파일 이름 변경**

```bash
mv .voice-persona.json .voice.json
```

- [ ] **Step 5: 커밋**

```bash
git add .gitignore
git commit -m "chore: 의존성 추가 + .voice.json 설정 파일명 변경"
```

---

## Task 2: SttConfig 추가 + config.py 수정

**Files:**
- Modify: `hook_voice/config.py`
- Test: `tests/test_config.py`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_config.py` 끝에 추가:

```python
from hook_voice.config import SttConfig

def test_load_config_stt_defaults(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.stt.enabled is False
    assert cfg.stt.model == "mlx-community/whisper-small-mlx"
    assert cfg.stt.language == "ko"
    assert cfg.stt.sample_rate == 16000
    assert cfg.stt.announce is True

def test_load_config_stt_from_file(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({
        "stt": {
            "enabled": True,
            "model": "mlx-community/whisper-tiny-mlx",
            "language": "en",
            "sampleRate": 8000,
            "announce": False,
        }
    }))
    cfg = load_config(cfg_file)
    assert cfg.stt.enabled is True
    assert cfg.stt.model == "mlx-community/whisper-tiny-mlx"
    assert cfg.stt.language == "en"
    assert cfg.stt.sample_rate == 8000
    assert cfg.stt.announce is False

def test_load_config_voice_json_takes_priority(tmp_path):
    voice_json = tmp_path / ".voice.json"
    persona_json = tmp_path / ".voice-persona.json"
    voice_json.write_text(json.dumps({"minChars": 10}))
    persona_json.write_text(json.dumps({"minChars": 99}))
    # load_config에 경로 미지정 시 .voice.json 우선 탐색 — 이 테스트는 명시적 경로로 검증
    cfg = load_config(voice_json)
    assert cfg.min_chars == 10
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_config.py -v -k "stt or voice_json" 2>&1 | tail -15
```

Expected: `ImportError: cannot import name 'SttConfig'` 또는 `AttributeError: 'Config' object has no attribute 'stt'`

- [ ] **Step 3: `hook_voice/config.py` 수정**

파일 전체를 다음 내용으로 교체:

```python
# hook_voice/config.py
# 사용자 설정 파일 로더 및 기본값 관리
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

_logger = logging.getLogger(__name__)

_VOICE_JSON = Path(__file__).parent.parent / ".voice.json"
_VOICE_PERSONA_JSON = Path(__file__).parent.parent / ".voice-persona.json"

_KEY_MAP = {
    "autoSpeak": "auto_speak",
    "minChars": "min_chars",
    "voice": "voice",
    "summaryModel": "summary_model",
    "ttsSpeed": "tts_speed",
    "ttsInstruct": "tts_instruct",
    "skillCooldownMinutes": "skill_cooldown_minutes",
    "supertonicPort": "supertonic_port",
    "edgeTimeoutMs": "edge_timeout_ms",
    "supertonicTimeoutMs": "supertonic_timeout_ms",
    "allowInsecureTls": "allow_insecure_tls",
}


@dataclass
class GrafanaConfig:
    enabled: bool = False
    url: str = ""
    token: str = ""
    interval: int = 30
    alerts: list[str] = field(default_factory=list)


@dataclass
class SttConfig:
    enabled: bool = False
    model: str = "mlx-community/whisper-small-mlx"
    language: str = "ko"
    sample_rate: int = 16000
    announce: bool = True


@dataclass
class Config:
    auto_speak: bool = True
    min_chars: int = 50
    voice: str = "Sohee"
    summary_model: str = "gpt-5.4"
    tts_speed: float = 1.1
    tts_instruct: str = "밝고 활기차게 말해주세요"
    skill_cooldown_minutes: int = 30
    supertonic_port: int = 7788
    edge_timeout_ms: int = 10000
    supertonic_timeout_ms: int = 20000
    allow_insecure_tls: bool = True
    grafana: GrafanaConfig = field(default_factory=GrafanaConfig)
    stt: SttConfig = field(default_factory=SttConfig)


def _warn_invalid(key: str, value: object, fallback: object) -> None:
    _logger.warning(".voice.json 잘못된 값: %s=%r, 기본값 %r 사용", key, value, fallback)


def _normalize_config(kwargs: dict[str, object]) -> dict[str, object]:
    defaults = Config()

    def _normalize_int(key: str, minimum: int, maximum: int | None = None) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, int) or value < minimum or (maximum is not None and value > maximum):
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)

    def _normalize_float(key: str, minimum: float) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, (int, float)) or float(value) <= minimum:
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)
        else:
            kwargs[key] = float(value)

    def _normalize_bool(key: str) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, bool):
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)

    _normalize_bool("auto_speak")
    _normalize_bool("allow_insecure_tls")
    _normalize_int("min_chars", 0)
    _normalize_float("tts_speed", 0.0)
    _normalize_int("skill_cooldown_minutes", 0)
    _normalize_int("supertonic_port", 1, 65535)
    _normalize_int("edge_timeout_ms", 100)
    _normalize_int("supertonic_timeout_ms", 100)

    grafana = kwargs.get("grafana")
    if isinstance(grafana, GrafanaConfig):
        if grafana.interval < 5:
            _warn_invalid("grafana.interval", grafana.interval, defaults.grafana.interval)
            grafana.interval = defaults.grafana.interval
        if not isinstance(grafana.alerts, list) or not all(isinstance(a, str) for a in grafana.alerts):
            _warn_invalid("grafana.alerts", grafana.alerts, defaults.grafana.alerts)
            grafana.alerts = defaults.grafana.alerts

    return kwargs


def _find_default_config() -> Path | None:
    if _VOICE_JSON.exists():
        return _VOICE_JSON
    if _VOICE_PERSONA_JSON.exists():
        return _VOICE_PERSONA_JSON
    return None


def load_config(path: Path | None = None) -> Config:
    target = path or _find_default_config()
    if target is None or not target.exists():
        return Config()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        kwargs = {py_k: data[json_k] for json_k, py_k in _KEY_MAP.items() if json_k in data}
        if "grafana" in data:
            g = data["grafana"]
            kwargs["grafana"] = GrafanaConfig(
                enabled=g.get("enabled", False),
                url=g.get("url", ""),
                token=g.get("token", ""),
                interval=g.get("interval", 30),
                alerts=g.get("alerts", []),
            )
        if "stt" in data:
            s = data["stt"]
            kwargs["stt"] = SttConfig(
                enabled=s.get("enabled", False),
                model=s.get("model", "mlx-community/whisper-small-mlx"),
                language=s.get("language", "ko"),
                sample_rate=s.get("sampleRate", 16000),
                announce=s.get("announce", True),
            )
        kwargs = _normalize_config(kwargs)
        return Config(**kwargs)
    except json.JSONDecodeError as e:
        _logger.warning(".voice.json 파싱 실패, 기본값 사용: %s", e)
        return Config()
    except Exception as e:
        _logger.warning(".voice.json 로드 실패, 기본값 사용: %s", e)
        return Config()
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

```bash
.venv/bin/pytest tests/test_config.py -v 2>&1 | tail -20
```

Expected: 모든 테스트 PASSED.

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/config.py tests/test_config.py
git commit -m "feat: SttConfig 추가 + .voice.json 우선 탐색"
```

---

## Task 3: SpeechListener 클래스 구현

**Files:**
- Create: `hook_voice/speech_listener.py`
- Create: `tests/test_speech_listener.py`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_speech_listener.py` 신규 생성:

```python
# tests/test_speech_listener.py
# SpeechListener 상태 기계 및 에러 처리 테스트
import asyncio
import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from hook_voice.config import SttConfig
from hook_voice.speech_listener import SpeechListener


@pytest.fixture
def stt_config():
    return SttConfig(
        enabled=True,
        model="mlx-community/whisper-small-mlx",
        language="ko",
        sample_rate=16000,
        announce=False,
    )


@pytest.mark.asyncio
async def test_toggle_idle_to_recording(stt_config):
    listener = SpeechListener(stt_config)
    with patch("sounddevice.InputStream") as mock_cls:
        mock_stream = MagicMock()
        mock_cls.return_value = mock_stream
        result = await listener.toggle()
    assert result["state"] == "recording"
    assert listener.state == "recording"
    mock_stream.start.assert_called_once()


@pytest.mark.asyncio
async def test_toggle_recording_to_idle_short_buffer(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    # 100 샘플 = 0.006초 → 1초 미만 → 무시
    listener._buffer = [np.zeros((100, 1), dtype="float32")]
    listener._stream = MagicMock()
    result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("text") is None
    assert listener.state == "idle"


@pytest.mark.asyncio
async def test_toggle_recording_transcribes_long_buffer(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    # 32000 샘플 = 2초 → 전사 진행
    listener._buffer = [np.zeros((32000, 1), dtype="float32")]
    listener._stream = MagicMock()
    with patch.object(listener, "_transcribe", return_value="안녕하세요"), \
         patch.object(listener, "_type_text") as mock_type:
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result["text"] == "안녕하세요"
    mock_type.assert_called_once_with("안녕하세요")


@pytest.mark.asyncio
async def test_toggle_mic_error_returns_no_mic(stt_config):
    listener = SpeechListener(stt_config)
    with patch("sounddevice.InputStream", side_effect=Exception("PortAudioError: no device")):
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("error") == "no_mic"


@pytest.mark.asyncio
async def test_toggle_transcribe_error_returns_failed(stt_config):
    listener = SpeechListener(stt_config)
    listener.state = "recording"
    listener._buffer = [np.zeros((32000, 1), dtype="float32")]
    listener._stream = MagicMock()
    with patch.object(listener, "_transcribe", side_effect=RuntimeError("model error")):
        result = await listener.toggle()
    assert result["state"] == "idle"
    assert result.get("error") == "transcribe_failed"


@pytest.mark.asyncio
async def test_run_disabled_exits_on_shutdown(stt_config):
    stt_config.enabled = False
    listener = SpeechListener(stt_config)
    shutdown = asyncio.Event()
    shutdown.set()
    # enabled=False인 경우 shutdown 대기 후 반환 — 예외 없음
    await listener.run(shutdown)
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tests/test_speech_listener.py -v 2>&1 | tail -15
```

Expected: `ModuleNotFoundError: No module named 'hook_voice.speech_listener'`

- [ ] **Step 3: `hook_voice/speech_listener.py` 구현**

```python
# hook_voice/speech_listener.py
# 마이크 녹음 → mlx-whisper 전사 → 클립보드 붙여넣기 상태 기계
import asyncio
import logging
import shlex
import subprocess
from typing import Literal

import numpy as np

from .config import SttConfig

_log = logging.getLogger(__name__)


class SpeechListener:
    def __init__(self, config: SttConfig) -> None:
        self._config = config
        self.state: Literal["idle", "recording"] = "idle"
        self._buffer: list[np.ndarray] = []
        self._stream = None
        self._lock = asyncio.Lock()

    async def toggle(self) -> dict:
        async with self._lock:
            if self.state == "idle":
                return await self._start_recording()
            return await self._stop_recording()

    async def _start_recording(self) -> dict:
        import sounddevice as sd
        self._buffer = []
        try:
            self._stream = sd.InputStream(
                samplerate=self._config.sample_rate,
                channels=1,
                dtype="float32",
                callback=self._audio_callback,
            )
            self._stream.start()
            self.state = "recording"
            _log.info("[STT] 녹음 시작")
            return {"state": "recording", "text": None}
        except Exception as e:
            _log.error("[STT] 마이크 오류: %s", e)
            return {"state": "idle", "error": "no_mic", "text": None}

    async def _stop_recording(self) -> dict:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        self.state = "idle"

        if not self._buffer:
            _log.info("[STT] 버퍼 비어있음 — 무시")
            return {"state": "idle", "text": None}

        audio = np.concatenate(self._buffer, axis=0).flatten()
        duration = len(audio) / self._config.sample_rate
        if duration < 1.0:
            _log.info("[STT] 녹음 너무 짧음 (%.2fs) — 무시", duration)
            return {"state": "idle", "text": None}

        try:
            loop = asyncio.get_running_loop()
            text = await loop.run_in_executor(None, self._transcribe, audio)
            if text:
                await loop.run_in_executor(None, self._type_text, text)
            _log.info("[STT] 전사 완료: %s", text[:40] if text else "(빈 결과)")
            return {"state": "idle", "text": text}
        except Exception as e:
            _log.error("[STT] 전사 실패: %s", e)
            return {"state": "idle", "error": "transcribe_failed", "text": None}

    def _audio_callback(self, indata: np.ndarray, frames: int, time, status) -> None:
        self._buffer.append(indata.copy())

    def _transcribe(self, audio: np.ndarray) -> str:
        import mlx_whisper
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._config.model,
            language=self._config.language,
        )
        return result.get("text", "").strip()

    def _type_text(self, text: str) -> None:
        subprocess.run(
            ["bash", "-c", f"printf '%s' {shlex.quote(text)} | pbcopy"],
            check=False,
        )
        subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to keystroke "v" using command down'],
            check=False,
        )

    async def run(self, shutdown: asyncio.Event) -> None:
        if not self._config.enabled:
            _log.info("[STT] 비활성화 (enabled=False)")
            await shutdown.wait()
            return
        _log.info("[STT] SpeechListener 준비 (model=%s)", self._config.model)
        await shutdown.wait()
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

```bash
.venv/bin/pytest tests/test_speech_listener.py -v 2>&1 | tail -20
```

Expected: 6개 테스트 모두 PASSED.

- [ ] **Step 5: 전체 테스트 회귀 확인**

```bash
.venv/bin/pytest tests/ -v --tb=short 2>&1 | tail -20
```

Expected: 모든 기존 테스트 PASSED.

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/speech_listener.py tests/test_speech_listener.py
git commit -m "feat: SpeechListener — 마이크 녹음·mlx-whisper 전사·클립보드 주입"
```

---

## Task 4: FastAPI 서버에 STT 엔드포인트 추가

**Files:**
- Modify: `tts_server/server.py`
- Test: `tts_server/test_server.py` (STT 엔드포인트 케이스 추가)

- [ ] **Step 1: 실패하는 테스트 작성**

`tts_server/test_server.py` 파일에서 `from fastapi.testclient import TestClient` 섹션을 찾아 그 아래에 추가:

```python
# ── STT 엔드포인트 테스트 ──────────────────────────────────────

def test_stt_status_disabled():
    """STT 비활성화 시 /stt/status → {"state": "disabled"}"""
    from unittest.mock import patch
    # _stt_listener가 None인 상태 (기본)
    import tts_server.server as srv
    original = srv._stt_listener
    srv._stt_listener = None
    try:
        with TestClient(app) as client:
            resp = client.get("/stt/status")
        assert resp.status_code == 200
        assert resp.json() == {"state": "disabled"}
    finally:
        srv._stt_listener = original


def test_stt_toggle_disabled_returns_503():
    """STT 비활성화 시 /stt/toggle → 503"""
    from unittest.mock import patch
    import tts_server.server as srv
    original = srv._stt_listener
    srv._stt_listener = None
    try:
        with TestClient(app) as client:
            resp = client.post("/stt/toggle")
        assert resp.status_code == 503
    finally:
        srv._stt_listener = original


def test_stt_toggle_calls_listener():
    """_stt_listener가 있을 때 /stt/toggle → toggle() 반환값 전달"""
    from unittest.mock import AsyncMock, patch
    import tts_server.server as srv
    mock_listener = AsyncMock()
    mock_listener.toggle = AsyncMock(return_value={"state": "recording", "text": None})
    mock_listener.state = "idle"
    original = srv._stt_listener
    srv._stt_listener = mock_listener
    try:
        with TestClient(app) as client:
            resp = client.post("/stt/toggle")
        assert resp.status_code == 200
        assert resp.json()["state"] == "recording"
    finally:
        srv._stt_listener = original
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

```bash
.venv/bin/pytest tts_server/test_server.py -v -k "stt" 2>&1 | tail -15
```

Expected: `AttributeError: module 'tts_server.server' has no attribute '_stt_listener'`

- [ ] **Step 3: `tts_server/server.py` 수정**

파일 상단 import 블록(대략 줄 14 `from fastapi` 앞)에 추가:

```python
from hook_voice.config import load_config as _load_voice_config
from hook_voice.speech_listener import SpeechListener
```

`app = FastAPI(...)` 선언 바로 앞에 전역 변수 추가:

```python
_stt_listener: SpeechListener | None = None
```

`lifespan` 함수의 `yield` 앞(기존 `_worker_thread.start()` 다음)에 추가:

```python
    global _stt_listener
    _voice_cfg = _load_voice_config()
    if _voice_cfg.stt.enabled:
        _stt_listener = SpeechListener(_voice_cfg.stt)
        _log("INFO", f"[STT] SpeechListener 초기화 (model={_voice_cfg.stt.model})")
```

파일 끝 `@app.get("/health")` 블록 다음에 엔드포인트 추가:

```python
@app.post("/stt/toggle")
async def stt_toggle():
    """STT 토글 — idle→recording 또는 recording→idle 전환."""
    if _stt_listener is None:
        return JSONResponse({"error": "STT 비활성화"}, status_code=503)
    result = await _stt_listener.toggle()
    return result


@app.get("/stt/status")
async def stt_status():
    """STT 현재 상태 반환."""
    if _stt_listener is None:
        return {"state": "disabled"}
    return {"state": _stt_listener.state}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

```bash
.venv/bin/pytest tts_server/test_server.py -v -k "stt" 2>&1 | tail -15
```

Expected: 3개 STT 테스트 PASSED.

- [ ] **Step 5: 전체 테스트 회귀 확인**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py -v --tb=short 2>&1 | tail -20
```

Expected: 모든 테스트 PASSED.

- [ ] **Step 6: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "feat: FastAPI /stt/toggle · /stt/status 엔드포인트 추가"
```

---

## Task 5: hooks/listen.sh + .claude/settings.json 등록

**Files:**
- Create: `hooks/listen.sh`
- Modify: `.claude/settings.json`

- [ ] **Step 1: `hooks/listen.sh` 생성**

```bash
#!/usr/bin/env bash
# STT 토글 — Claude Code /listen slash 명령에서 호출
curl -s -X POST http://localhost:7777/stt/toggle \
  && echo '{"continue": true}' \
  || echo '{"continue": false, "error": "STT 서버가 응답하지 않습니다"}'
```

실행 권한 부여:

```bash
chmod +x hooks/listen.sh
```

- [ ] **Step 2: `/listen` slash 명령 작동 확인 (서버 기동 상태에서)**

```bash
./hooks/listen.sh
```

Expected (서버 미구동 시): `{"continue": false, "error": "STT 서버가 응답하지 않습니다"}`  
Expected (서버 구동·STT 비활성화 시): `{"error": "STT 비활성화"}{"continue": true}`

- [ ] **Step 3: `.claude/settings.json`에 /listen 명령 등록**

`.claude/settings.json`의 기존 `"hooks"` 객체 옆에 `"commands"` 추가:

```json
{
  "hooks": { "...": "..." },
  "commands": {
    "listen": {
      "description": "음성 입력 토글 (녹음 시작/중지)",
      "command": "hooks/listen.sh"
    }
  }
}
```

- [ ] **Step 4: Hammerspoon 스니펫 생성 (선택 설치)**

`~/.hammerspoon/init.lua` 끝에 아래 내용을 **사용자가 직접 추가**한다 (자동 수정 없음):

```lua
-- Whisper STT 토글 (Cmd+Shift+Space)
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  local task = hs.task.new("/usr/bin/curl", nil, {
    "-s", "-X", "POST", "http://localhost:7777/stt/toggle"
  })
  task:start()
end)
```

Hammerspoon 메뉴 → **Reload Config** 적용.

- [ ] **Step 5: 커밋**

```bash
git add hooks/listen.sh .claude/settings.json
git commit -m "feat: /listen slash 명령 + Hammerspoon STT 토글 안내"
```

---

## Task 6: .voice.json STT 설정 활성화 + 서버 재시작 검증

**Files:**
- Modify: `.voice.json` (gitignore 파일 — 커밋 없음)

- [ ] **Step 1: `.voice.json`에 STT 섹션 추가**

`.voice.json` 파일을 열어 `"stt"` 키 추가:

```json
{
  "grafana": {
    "enabled": true,
    "url": "https://hubble-krnw-platform.hmg-corp.io/grafana",
    "token": "<토큰>",
    "interval": 30,
    "alerts": []
  },
  "stt": {
    "enabled": true,
    "model": "mlx-community/whisper-small-mlx",
    "language": "ko",
    "sampleRate": 16000,
    "announce": true
  }
}
```

- [ ] **Step 2: 서버 재시작**

```bash
./server.sh restart
```

Expected: 로그에 `[STT] SpeechListener 초기화 (model=mlx-community/whisper-small-mlx)` 출력.

- [ ] **Step 3: STT 상태 확인**

```bash
curl -s http://localhost:7777/stt/status
```

Expected: `{"state": "idle"}`

- [ ] **Step 4: 토글 테스트**

```bash
curl -s -X POST http://localhost:7777/stt/toggle
```

Expected: `{"state": "recording", "text": null}`

```bash
sleep 3 && curl -s -X POST http://localhost:7777/stt/toggle
```

Expected: `{"state": "idle", "text": "...전사된 텍스트..."}` 또는 `{"state": "idle", "text": null}` (무음 시)

---

## 완료 기준

- [ ] `SttConfig`가 `.voice.json`에서 파싱됨
- [ ] `POST /stt/toggle` → idle↔recording 전환, 전사 결과 반환
- [ ] `GET /stt/status` → `{"state": "idle"|"recording"|"disabled"}`
- [ ] 1초 미만 녹음은 무시됨
- [ ] 마이크 없음 / 전사 실패 시 idle로 안전 복귀
- [ ] Hammerspoon 단축키 또는 `/listen` 명령으로 토글 가능
- [ ] 전체 테스트 PASSED (`pytest tests/ tts_server/test_server.py`)
