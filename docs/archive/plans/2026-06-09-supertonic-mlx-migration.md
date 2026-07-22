# supertonic MLX 마이그레이션 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** supertonic ONNX → MLX 전환, Qwen TTS 및 모든 폴백 코드 제거, 더 이상 사용하지 않는 코드 정리

**Architecture:** `ailuntx/supertonic-mlx` 런타임으로 `mlx-community/supertonic-3` 모델을 구동하는 FastAPI 서버(`tts_server/supertonic_mlx_server.py`)를 신규 작성하고, `supervisor.py`의 `_start_supertonic()`이 이 서버를 실행하도록 교체한다. `player.py`에서 Qwen CLI / macOS say / 7777 HTTP 등 모든 폴백 경로를 제거하고, `server.py`에서 Qwen `_tts_worker`·`/speak` 엔드포인트를 제거한다(STT·메트릭·DLQ 엔드포인트는 유지).

**Tech Stack:** `ailuntx/supertonic-mlx` (SupertonicMLX), `mlx 0.31.2`, `fastapi`, `uvicorn`, `httpx`, `edge_tts`, `pytest-asyncio`

---

## 파일 변경 맵

| 파일 | 작업 | 설명 |
|---|---|---|
| `tts_server/supertonic_mlx_server.py` | **신규** | MLX 기반 TTS 서버 (포트 7788) |
| `hook_voice/player.py` | **대폭 수정** | Qwen/폴백 코드 제거, speak_hook·speak_agent 단순화 |
| `tts_server/server.py` | **대폭 수정** | Qwen 워커·/speak 제거, STT·메트릭 유지 |
| `tts_server/supervisor.py` | **수정** | `_start_supertonic()` → MLX 서버 실행으로 교체 |
| `tests/test_player.py` | **재작성** | 폴백 테스트 제거, 단순화된 player 테스트 |
| `tts_server/test_server.py` | **수정** | speak/worker 관련 테스트 제거, _preprocess_for_tts 이동 반영 |

---

## Task 1: supertonic-mlx 패키지 설치 + 모델 다운로드

**Files:**
- Modify: `.venv` (pip install)
- 모델 캐시: `~/.cache/supertonic3-mlx/`

- [ ] **Step 1: supertonic-mlx 패키지 설치**

```bash
.venv/bin/pip install git+https://github.com/ailuntx/supertonic-mlx.git
```

Expected: `Successfully installed supertonic-mlx-...`

- [ ] **Step 2: 설치 확인**

```bash
.venv/bin/python -c "from supertonic_mlx import SupertonicMLX, Style; print('OK')"
```

Expected: `OK`

- [ ] **Step 3: 모델 다운로드** (HF_HUB_OFFLINE 임시 해제, HMG SSL 우회 필요)

```bash
HF_HUB_OFFLINE=0 PYTHONHTTPSVERIFY=0 .venv/bin/python -c "
import ssl, urllib.request
ssl._create_default_https_context = ssl._create_unverified_context
from huggingface_hub import snapshot_download
snapshot_download(
    'mlx-community/supertonic-3',
    local_dir='/Users/hmc7102758/.cache/supertonic3-mlx',
)
print('다운로드 완료')
"
```

Expected: `다운로드 완료`  
실패 시: `HUGGINGFACE_HUB_VERBOSITY=debug` 추가 후 SSL 오류 확인 → `REQUESTS_CA_BUNDLE=""` 도 시도

- [ ] **Step 4: 모델 파일 확인**

```bash
ls ~/.cache/supertonic3-mlx/
# 기대: graphs/ weights/ voice_styles/ tts.json unicode_indexer.json
```

- [ ] **Step 5: 기본 추론 동작 확인**

```bash
.venv/bin/python -c "
from supertonic_mlx import SupertonicMLX
import soundfile as sf, numpy as np
m = SupertonicMLX('/Users/hmc7102758/.cache/supertonic3-mlx')
style = m.get_voice_style('M2')
wav, dur = m.synthesize('안녕하세요.', 'ko', style, total_step=4)
sf.write('/tmp/test_mlx.wav', wav[0], m.sample_rate)
print('sample_rate:', m.sample_rate, '| 길이(s):', round(float(dur[0]), 2))
"
```

Expected: `sample_rate: 44100 | 길이(s): 1.xx`

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "chore: supertonic-mlx 패키지 설치 및 모델 다운로드"
```

---

## Task 2: tts_server/supertonic_mlx_server.py 신규 작성

**Files:**
- Create: `tts_server/supertonic_mlx_server.py`

Task 1 완료 후 진행.

- [ ] **Step 1: 서버 파일 작성**

`tts_server/supertonic_mlx_server.py` 를 다음 내용으로 생성:

```python
# tts_server/supertonic_mlx_server.py
# ailuntx/supertonic-mlx 기반 FastAPI TTS 서버 — 포트 7788
from __future__ import annotations

import asyncio
import io
import re
from contextlib import asynccontextmanager
from pathlib import Path

import soundfile as sf
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

MODEL_DIR = Path.home() / ".cache" / "supertonic3-mlx"

# 한국어 TTS에서 발음이 부자연스러운 영문 기술 용어 → 한국어 발음 치환 사전
_TECH_PHONETICS: dict[str, str] = {
    "HTTP": "에이치티티피", "HTTPS": "에이치티티피에스",
    "gRPC": "지알피씨", "GRPC": "지알피씨", "RPC": "알피씨",
    "REST": "레스트", "WebSocket": "웹소켓", "WebSockets": "웹소켓",
    "TCP": "티씨피", "UDP": "유디피", "TLS": "티엘에스", "SSL": "에스에스엘",
    "DNS": "디엔에스", "IP": "아이피", "IPv4": "아이피브이사", "IPv6": "아이피브이육",
    "API": "에이피아이", "SDK": "에스디케이", "JWT": "제이더블유티",
    "OAuth": "오오스", "SSO": "에스에스오", "RBAC": "알백", "MFA": "엠에프에이",
    "AWS": "에이더블유에스", "GCP": "지씨피", "K8s": "케이에이츠",
    "CI": "씨아이", "CD": "씨디", "DevOps": "데브옵스", "Docker": "도커",
    "Kubernetes": "쿠버네티스", "Helm": "헬름", "OTel": "오텔", "OTLP": "오티엘피",
    "Prometheus": "프로메테우스", "Grafana": "그라파나", "Kafka": "카프카",
    "Redis": "레디스", "Nginx": "엔진엑스",
    "LLM": "엘엘엠", "MLX": "엠엘엑스", "TTS": "티티에스", "STT": "에스티티",
    "AI": "에이아이", "ML": "엠엘", "MCP": "엠씨피", "RAG": "래그",
    "GPU": "지피유", "CPU": "씨피유", "TPU": "티피유",
    "OpenAI": "오픈에이아이", "ChatGPT": "챗지피티", "GPT": "지피티",
    "Claude": "클로드",
    "JSON": "제이슨", "YAML": "야믈", "CSV": "씨에스브이",
    "SQL": "에스큐엘", "NoSQL": "노에스큐엘", "XML": "엑스엠엘",
    "gzip": "지집", "Parquet": "파케이",
    "GitHub": "깃허브", "GitLab": "깃랩", "Slack": "슬랙",
    "Linux": "리눅스", "macOS": "맥오에스", "iOS": "아이오에스",
    "Android": "안드로이드",
}
_TECH_UPPER: dict[str, str] = {k.upper(): v for k, v in _TECH_PHONETICS.items()}


def _preprocess(text: str) -> str:
    """영문 기술 용어를 한국어 발음으로 치환한다."""
    return re.sub(
        r"[A-Za-z][A-Za-z0-9\-/\.]*",
        lambda m: _TECH_UPPER.get(m.group(0).upper(), m.group(0)),
        text,
    )


_model = None
_lock: asyncio.Lock | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model, _lock
    from supertonic_mlx import SupertonicMLX
    _model = SupertonicMLX(MODEL_DIR)
    _lock = asyncio.Lock()
    # Metal GPU 워밍업 — 첫 추론 시 컴파일 시간 선행 처리
    style = _model.get_voice_style("M1")
    _model.synthesize("워밍업.", "ko", style, total_step=2)
    yield
    _model = None


app = FastAPI(title="Supertonic MLX Server", lifespan=lifespan)


class TTSRequest(BaseModel):
    text: str
    lang: str = "ko"
    voice: str = "M1"
    steps: int = 8
    speed: float = 1.05
    response_format: str = "wav"


@app.get("/v1/health")
async def health():
    return {"status": "ok"}


@app.post("/v1/tts")
async def tts(req: TTSRequest):
    if _model is None or _lock is None:
        raise HTTPException(503, "모델 로딩 중")
    processed = _preprocess(req.text)
    async with _lock:
        style = _model.get_voice_style(req.voice)
        wav, _ = _model.synthesize(
            processed, req.lang, style,
            total_step=req.steps, speed=req.speed,
        )
    buf = io.BytesIO()
    sf.write(buf, wav[0], _model.sample_rate, format="WAV")
    return Response(buf.getvalue(), media_type="audio/wav")
```

- [ ] **Step 2: 단위 테스트 작성**

`tts_server/test_supertonic_mlx_server.py` 생성:

```python
# tts_server/test_supertonic_mlx_server.py
import sys
import types

# supertonic_mlx 없는 CI 환경에서도 통과하도록 stub
stub = types.ModuleType("supertonic_mlx")
stub.SupertonicMLX = None
sys.modules.setdefault("supertonic_mlx", stub)

from tts_server.supertonic_mlx_server import _preprocess


class TestPreprocess:
    def test_docker_replaced(self):
        assert _preprocess("Docker") == "도커"

    def test_case_insensitive(self):
        assert _preprocess("docker") == "도커"
        assert _preprocess("DOCKER") == "도커"

    def test_unknown_word_unchanged(self):
        assert "SomeWord" in _preprocess("SomeWord")

    def test_mixed_sentence(self):
        result = _preprocess("API와 Docker를 사용합니다")
        assert "에이피아이" in result
        assert "도커" in result
```

- [ ] **Step 3: 테스트 실행**

```bash
.venv/bin/pytest tts_server/test_supertonic_mlx_server.py -v
```

Expected: 4 passed

- [ ] **Step 4: 커밋**

```bash
git add tts_server/supertonic_mlx_server.py tts_server/test_supertonic_mlx_server.py
git commit -m "feat: supertonic MLX FastAPI 서버 신규 작성"
```

---

## Task 3: hook_voice/player.py — Qwen 폴백 코드 제거 및 단순화

**Files:**
- Modify: `hook_voice/player.py`
- Modify: `tests/test_player.py`

Task 1, 2와 병렬 진행 가능.

- [ ] **Step 1: player.py 전체 교체**

`hook_voice/player.py` 를 다음 내용으로 교체:

```python
# hook_voice/player.py
# EdgeTTS spool enqueue, speak_hook / speak_agent
import asyncio
import logging
import random
import ssl
import string
import tempfile
import time
from pathlib import Path

import edge_tts
import edge_tts.communicate as _ec
import httpx

from .last_message import save_last_message
from .observability.circuit_breaker import get_circuit_breaker

_log = logging.getLogger(__name__)

# HMG 사내 SSL 프록시 우회 — edge_tts 내부 SSL 컨텍스트 교체
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE
_ec._SSL_CTX = _ssl_ctx

SPOOL_DIR = Path("/tmp/tts-spool")
EDGE_VOICE = "ko-KR-HyunsuMultilingualNeural"


def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(speed * 100))
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)


async def _generate_edge(text: str) -> Path:
    out = Path(tempfile.mktemp(suffix=".mp3", prefix="vp_edge_"))
    comm = edge_tts.Communicate(text, EDGE_VOICE)
    await comm.save(str(out))
    return out


async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2,
                     edge_timeout: float = 10.0) -> None:
    edge_cb = get_circuit_breaker("edge_tts")

    async def _edge_call() -> Path:
        return await asyncio.wait_for(_generate_edge(text), timeout=edge_timeout)

    try:
        mp3 = await edge_cb.call(_edge_call, fallback=None)
        if mp3 is not None:
            _enqueue_spool(mp3, speed)
            save_last_message(text)
    except Exception as e:
        _log.warning("EdgeTTS 생성 실패: %s", type(e).__name__)


async def _generate_supertonic(
    text: str, voice: str, port: int, steps: int = 12, timeout: float = 20.0
) -> bytes:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"http://localhost:{port}/v1/tts",
            json={"text": text, "voice": voice, "lang": "ko",
                  "steps": steps, "response_format": "wav"},
            timeout=timeout,
        )
        r.raise_for_status()
        return r.content


def _dynamic_steps(text: str, base_steps: int) -> int:
    """텍스트 길이에 따라 diffusion steps 동적 조정 — 100자 미만이면 최소 8 steps."""
    return min(8, base_steps) if len(text) < 100 else base_steps


async def speak_agent(text: str, voice: str, port: int, speed: float, instruct: str = "",
                      steps: int = 12, supertonic_timeout: float = 20.0) -> None:
    if not text.strip():
        return
    actual_steps = _dynamic_steps(text, steps)
    st_cb = get_circuit_breaker("supertonic")

    async def _st_call() -> bytes:
        return await asyncio.wait_for(
            _generate_supertonic(text, voice, port, steps=actual_steps, timeout=supertonic_timeout),
            timeout=supertonic_timeout,
        )

    try:
        wav_bytes = await st_cb.call(_st_call, fallback=None)
        if wav_bytes is not None:
            tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
    except Exception as e:
        _log.warning("Supertonic 생성 실패: %s", type(e).__name__)
```

- [ ] **Step 2: test_player.py 재작성**

`tests/test_player.py` 를 다음 내용으로 교체:

```python
# tests/test_player.py
import pytest
import time
from pathlib import Path
from unittest.mock import AsyncMock, patch

import hook_voice.player as player_module
from hook_voice.player import speak_hook, speak_agent, _enqueue_spool, _dynamic_steps
from hook_voice.observability.circuit_breaker import _breakers, CBState


@pytest.fixture(autouse=True)
def reset_cbs():
    yield
    for cb in list(_breakers.values()):
        cb.reset()
    _breakers.clear()


# ── _enqueue_spool ───────────────────────────────────────────────────────────

def test_enqueue_spool_moves_file_and_encodes_speed(tmp_path):
    """_enqueue_spool이 파일을 이동하고 파일명에 speed를 인코딩한다."""
    src = tmp_path / "audio.mp3"
    src.write_bytes(b"fake mp3")
    spool = tmp_path / "spool"
    spool.mkdir()

    with patch("hook_voice.player.SPOOL_DIR", spool):
        _enqueue_spool(src, 1.2)

    mp3_files = list(spool.glob("*.mp3"))
    assert len(mp3_files) == 1
    assert "_120." in mp3_files[0].name
    assert not src.exists()


def test_enqueue_spool_encodes_speed_125(tmp_path):
    """speed=1.25 → 파일명에 _125. 인코딩."""
    original = player_module.SPOOL_DIR
    player_module.SPOOL_DIR = tmp_path
    try:
        src = tmp_path / "source.wav"
        src.write_bytes(b"RIFF")
        _enqueue_spool(src, 1.25)
        files = list(tmp_path.glob("*.wav"))
        assert len(files) == 1
        assert "_125." in files[0].name
        assert len(list(tmp_path.glob("*.meta"))) == 0
    finally:
        player_module.SPOOL_DIR = original


# ── _dynamic_steps ───────────────────────────────────────────────────────────

def test_dynamic_steps_short_text_capped_at_8():
    assert _dynamic_steps("짧은 텍스트", base_steps=12) == 8


def test_dynamic_steps_long_text_returns_base():
    long = "가" * 110
    assert _dynamic_steps(long, base_steps=10) == 10


# ── speak_hook ───────────────────────────────────────────────────────────────

async def test_speak_hook_enqueues_via_edge(tmp_path, monkeypatch):
    """EdgeTTS 성공 시 mp3 파일이 spool에 저장된다."""
    mp3_src = tmp_path / "edge.mp3"
    mp3_src.write_bytes(b"fake")
    spool = tmp_path / "spool"
    spool.mkdir()

    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    async def fake_generate_edge(text):
        mp3_src.write_bytes(b"fake")
        return mp3_src

    with patch("hook_voice.player._generate_edge", side_effect=fake_generate_edge):
        await speak_hook("안녕하세요", "Sohee", 1.2)

    assert len(list(spool.glob("*.mp3"))) == 1


async def test_speak_hook_logs_warning_on_edge_failure(tmp_path, monkeypatch, caplog):
    """EdgeTTS 실패 시 예외를 전파하지 않고 경고 로그를 남긴다."""
    import logging
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", tmp_path)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_edge", side_effect=Exception("EdgeTTS 실패")):
        with caplog.at_level(logging.WARNING, logger="hook_voice.player"):
            await speak_hook("안녕", "Sohee", 1.2)

    assert any("EdgeTTS" in r.message for r in caplog.records)


# ── speak_agent ──────────────────────────────────────────────────────────────

async def test_speak_agent_enqueues_wav(tmp_path, monkeypatch):
    """Supertonic 성공 시 wav 파일이 spool에 저장된다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", new=AsyncMock(return_value=b"RIFF....WAV")):
        await speak_agent("빌더입니다. 작업 완료", "M4", 7788, 1.2)

    assert len(list(spool.glob("*.wav"))) == 1


async def test_speak_agent_passes_adjusted_steps(tmp_path, monkeypatch):
    """speak_agent가 _dynamic_steps로 조정된 steps를 전달한다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    long_text = "가" * 110
    mock_gen = AsyncMock(return_value=b"RIFF")
    with patch("hook_voice.player._generate_supertonic", new=mock_gen):
        await speak_agent(long_text, "M2", 7788, 1.2, steps=10)

    assert mock_gen.call_args.kwargs.get("steps") == 10


async def test_speak_agent_skips_empty_text():
    """빈 텍스트는 _generate_supertonic을 호출하지 않는다."""
    mock_gen = AsyncMock()
    with patch("hook_voice.player._generate_supertonic", new=mock_gen):
        await speak_agent("", "M4", 7788, 1.2)
    mock_gen.assert_not_called()


async def test_speak_agent_logs_on_failure(monkeypatch, caplog):
    """Supertonic 실패 시 예외를 전파하지 않고 경고 로그를 남긴다."""
    import logging
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_supertonic", side_effect=Exception("ST 실패")):
        with caplog.at_level(logging.WARNING, logger="hook_voice.player"):
            await speak_agent("테스트", "M2", 7788, 1.0)

    assert any("Supertonic" in r.message for r in caplog.records)


# ── _generate_supertonic ─────────────────────────────────────────────────────

async def test_generate_supertonic_posts_to_v1_tts():
    """_generate_supertonic이 /v1/tts에 steps를 포함해 POST한다."""
    from hook_voice.player import _generate_supertonic

    captured = {}

    class FakeResponse:
        status_code = 200
        content = b"RIFF_WAV"
        def raise_for_status(self): pass

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass
        async def post(self, url, json=None, timeout=None):
            captured["url"] = url
            captured["json"] = json
            return FakeResponse()

    with patch("hook_voice.player.httpx.AsyncClient", return_value=FakeClient()):
        result = await _generate_supertonic("안녕하세요", "M4", 7788, steps=10)

    assert result == b"RIFF_WAV"
    assert "/v1/tts" in captured["url"]
    assert captured["json"]["steps"] == 10
    assert captured["json"]["voice"] == "M4"


# ── Circuit Breaker ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_speak_hook_edge_cb_opens_after_failures(monkeypatch, tmp_path):
    """EdgeTTS가 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["edge_tts"] = CircuitBreaker("edge_tts", CircuitBreakerConfig(failure_threshold=3))

    monkeypatch.setattr(player_module, "_speak_without_edge", None, raising=False)
    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)
    monkeypatch.setattr(player_module, "SPOOL_DIR", tmp_path)

    async def fail_edge(text):
        raise OSError("edge fail")

    monkeypatch.setattr(player_module, "_generate_edge", fail_edge)

    for _ in range(3):
        await speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)

    assert _breakers["edge_tts"].state == CBState.OPEN


@pytest.mark.asyncio
async def test_speak_hook_edge_cb_open_skips_generate(monkeypatch, tmp_path):
    """EdgeTTS CB가 OPEN이면 _generate_edge를 호출하지 않는다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig, CBState as _CBState

    cb = CircuitBreaker("edge_tts", CircuitBreakerConfig(failure_threshold=3, recovery_timeout=60.0))
    cb._state = _CBState.OPEN
    cb._opened_at = time.time()
    _breakers["edge_tts"] = cb

    called = []

    async def should_not_be_called(text):
        called.append(text)

    monkeypatch.setattr(player_module, "_generate_edge", should_not_be_called)
    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)
    monkeypatch.setattr(player_module, "SPOOL_DIR", tmp_path)

    await speak_hook("test", voice="Sohee", speed=1.0, edge_timeout=1.0)
    assert called == []


@pytest.mark.asyncio
async def test_speak_agent_supertonic_cb_opens_after_failures(monkeypatch):
    """Supertonic이 연속 3회 실패하면 CB가 OPEN으로 전환된다."""
    from hook_voice.observability.circuit_breaker import CircuitBreaker, CircuitBreakerConfig

    _breakers["supertonic"] = CircuitBreaker("supertonic", CircuitBreakerConfig(failure_threshold=3))

    async def fail_st(*args, **kwargs):
        raise OSError("supertonic fail")

    monkeypatch.setattr(player_module, "_generate_supertonic", fail_st)
    monkeypatch.setattr(player_module, "save_last_message", lambda t: None)

    for _ in range(3):
        await speak_agent("test", "M2", port=7788, speed=1.0)

    assert _breakers["supertonic"].state == CBState.OPEN
```

- [ ] **Step 3: 테스트 실행**

```bash
.venv/bin/pytest tests/test_player.py -v
```

Expected: 전체 통과

- [ ] **Step 4: 커밋**

```bash
git add hook_voice/player.py tests/test_player.py
git commit -m "refactor: player.py Qwen·폴백 코드 제거, speak_hook·speak_agent 단순화"
```

---

## Task 4: tts_server/server.py — Qwen 워커 제거, STT·메트릭 유지

**Files:**
- Modify: `tts_server/server.py`
- Modify: `tts_server/test_server.py`

Task 2, 3와 병렬 진행 가능.

- [ ] **Step 1: server.py 교체**

`tts_server/server.py` 를 다음 내용으로 교체 (Qwen `_tts_worker`, `/speak`, `_MODEL_ID`, `_TECH_PHONETICS` 제거):

```python
# tts_server/server.py
# FastAPI 보조 서버 — STT·메트릭·DLQ 엔드포인트 (포트 7777)
import datetime
import os

os.environ["HF_HUB_OFFLINE"] = "1"

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from hook_voice.config import load_config as _load_voice_config
from hook_voice.observability.metrics import get_registry as _get_metrics
from hook_voice.observability.dlq import get_dlq_store as _get_dlq_store, ReplayStatus
from hook_voice.speech_listener import SpeechListener

_stt_listener: SpeechListener | None = None


def _log(level: str, message: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{level}] {ts} {message}", flush=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _stt_listener
    _voice_cfg = _load_voice_config()
    if _voice_cfg.stt.enabled:
        _stt_listener = SpeechListener(_voice_cfg.stt)
        _log("INFO", f"[STT] SpeechListener 초기화 (model={_voice_cfg.stt.model})")
    yield
    if _stt_listener is not None and _stt_listener.state == "recording":
        await _stt_listener.toggle()
    _log("INFO", "서버 종료.")


app = FastAPI(title="Chorus Aux Server", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/stt/toggle")
async def stt_toggle():
    if _stt_listener is None:
        return JSONResponse({"status": "disabled", "detail": "STT 비활성화"}, status_code=503)
    result = await _stt_listener.toggle()
    return result


@app.get("/stt/status")
async def stt_status():
    if _stt_listener is None:
        return {"state": "disabled"}
    return {"state": _stt_listener.state}


@app.get("/metrics")
async def metrics_prometheus():
    from fastapi.responses import PlainTextResponse
    text = _get_metrics().to_prometheus_text()
    return PlainTextResponse(text, media_type="text/plain; version=0.0.4")


@app.get("/metrics/json")
async def metrics_json():
    from hook_voice.observability.circuit_breaker import _breakers
    snap = _get_metrics().snapshot()
    snap["circuit_breakers"] = {name: cb.state.value for name, cb in _breakers.items()}
    snap["dlq_pending"] = _get_dlq_store().stats().get("pending", 0)
    return snap


class DLQReplayRequest(BaseModel):
    entry_ids: list[int] = []
    replay_all_pending: bool = False


@app.post("/admin/dlq/replay")
async def dlq_replay(req: DLQReplayRequest):
    store = _get_dlq_store()
    if req.replay_all_pending:
        pending = store.list_pending(limit=200)
        ids = [e.id for e in pending if e.id is not None]
    else:
        ids = req.entry_ids
    results = []
    for eid in ids:
        ok = store.mark_replayed(eid)
        results.append({"id": eid, "status": "replayed" if ok else "not_found"})
    return {"replayed": len([r for r in results if r["status"] == "replayed"]), "details": results}


@app.get("/admin/dlq")
async def dlq_list(limit: int = 50, status: str | None = None):
    store = _get_dlq_store()
    entries = store.list_pending(limit=limit) if status == "pending" else store.list_all(limit=limit)
    return {
        "stats": store.stats(),
        "entries": [
            {
                "id": e.id, "event_id": e.event_id,
                "failure_stage": e.failure_stage, "failure_detail": e.failure_detail,
                "source": e.source, "severity": e.severity,
                "priority_score": e.priority_score,
                "replay_status": e.replay_status.value,
                "created_at": e.created_at, "replayed_at": e.replayed_at,
            }
            for e in entries
        ],
    }
```

- [ ] **Step 2: test_server.py 수정**

`tts_server/test_server.py` 에서 `_preprocess_for_tts` 관련 import와 테스트를 삭제하고, `_log` 테스트만 유지:

```python
# tts_server/test_server.py
# server.py 단위 테스트 — STT·로그·클린업 검증
import os
import time
import tempfile
import subprocess
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from tts_server.server import _log
from tts_server.supervisor import _do_cleanup


class TestStructuredLog:
    def test_info_prefix(self, capsys):
        _log("INFO", "서버 시작")
        assert "[INFO]" in capsys.readouterr().out

    def test_error_prefix(self, capsys):
        _log("ERROR", "오류 발생")
        assert "[ERROR]" in capsys.readouterr().out

    def test_timestamp_included(self, capsys):
        import re
        _log("INFO", "타임스탬프 확인")
        assert re.search(r"\d{4}-\d{2}-\d{2}", capsys.readouterr().out)


class TestSpoolCleanup:
    def test_old_files_removed(self, tmp_path):
        old = tmp_path / "old.wav"
        old.write_bytes(b"x")
        old_time = time.time() - 400
        os.utime(old, (old_time, old_time))
        _do_cleanup(tmp_path)
        assert not old.exists()

    def test_max_10_files_enforced(self, tmp_path):
        for i in range(12):
            f = tmp_path / f"{i:010d}_100.wav"
            f.write_bytes(b"x")
            t = time.time() - (12 - i)
            os.utime(f, (t, t))
        _do_cleanup(tmp_path)
        assert len(list(tmp_path.glob("*.wav"))) == 10


def test_stt_status_disabled():
    from fastapi.testclient import TestClient
    from tts_server.server import app
    with TestClient(app) as client:
        r = client.get("/stt/status")
    assert r.status_code == 200
    assert r.json()["state"] == "disabled"


def test_stt_toggle_disabled_returns_503():
    from fastapi.testclient import TestClient
    from tts_server.server import app
    with TestClient(app) as client:
        r = client.post("/stt/toggle")
    assert r.status_code == 503


def test_metrics_json_includes_cb_and_dlq():
    from fastapi.testclient import TestClient
    from tts_server.server import app
    with TestClient(app) as client:
        r = client.get("/metrics/json")
    assert r.status_code == 200
    data = r.json()
    assert "circuit_breakers" in data
    assert "dlq_pending" in data
```

- [ ] **Step 3: 테스트 실행**

```bash
.venv/bin/pytest tts_server/test_server.py -v
```

Expected: 전체 통과

- [ ] **Step 4: 커밋**

```bash
git add tts_server/server.py tts_server/test_server.py
git commit -m "refactor: server.py Qwen 워커·/speak 제거, STT·메트릭·DLQ만 유지"
```

---

## Task 5: tts_server/supervisor.py — _start_supertonic() 교체

**Files:**
- Modify: `tts_server/supervisor.py`

Task 2 완료 후 진행.

- [ ] **Step 1: _start_supertonic() 교체**

`tts_server/supervisor.py`의 `_start_supertonic()` 함수만 교체:

```python
def _start_supertonic() -> subprocess.Popen:
    """supertonic-mlx FastAPI 서버를 기동한다 (포트 7788, Metal GPU 단일 워커)."""
    with open("/tmp/supertonic.log", "a") as supertonic_log:
        return subprocess.Popen(
            [str(VENV_BIN / "uvicorn"),
             "tts_server.supertonic_mlx_server:app",
             "--host", "127.0.0.1",
             "--port", "7788",
             "--workers", "1"],
            env={**os.environ, "HF_HUB_OFFLINE": "1"},
            stdout=supertonic_log,
            stderr=supertonic_log,
            cwd=str(PROJECT_DIR),
        )
```

- [ ] **Step 2: test_supervisor.py에서 _start_supertonic 관련 테스트 확인 및 수정**

```bash
grep -n "supertonic\|start_super" /Users/hmc7102758/Develop/Workspaces/chorus/tts_server/test_supervisor.py
```

관련 테스트가 있으면 새 커맨드(`uvicorn ... supertonic_mlx_server:app`)를 검증하도록 수정.

- [ ] **Step 3: 전체 테스트 실행**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py tts_server/test_supertonic_mlx_server.py -v
```

Expected: 전체 통과

- [ ] **Step 4: 커밋**

```bash
git add tts_server/supervisor.py tts_server/test_supervisor.py
git commit -m "feat: supervisor _start_supertonic을 MLX 서버로 교체"
```

---

## Task 6: CLAUDE.md·AGENTS.md 문서 업데이트

**Files:**
- Modify: `CLAUDE.md`

Task 3~5 완료 후 진행.

- [ ] **Step 1: CLAUDE.md 아키텍처 흐름 업데이트**

`CLAUDE.md`의 "서브에이전트 응답 완료" 섹션에서 Supertonic 관련 설명을 MLX 기반으로 수정:

```
서브에이전트 응답 완료
  → SubagentStop hook
    → python -m hook_voice subagent-stop [agentType]
      ...
      → speak_agent() (hook_voice/player.py)
          ├─ Supertonic MLX: localhost:7788/v1/tts 확인 → WAV 생성
          └─ /tmp/tts-spool/<ts>_<rand>.wav 기록 → 즉시 반환
```

- [ ] **Step 2: 파일별 역할 표 업데이트**

`server.py` 행을 "STT·메트릭·DLQ 보조 서버"로, `supertonic_mlx_server.py`를 신규 추가.

- [ ] **Step 3: TTS 서버 설계 포인트 업데이트**

`supertonic serve` → `supertonic-mlx` 런타임으로 설명 수정.

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md supertonic MLX 마이그레이션 반영"
```

---

## Task 7: 통합 검증

- [ ] **Step 1: 전체 테스트 스위트 실행**

```bash
.venv/bin/pytest tests/ tts_server/ -v --tb=short 2>&1 | tail -30
```

Expected: 전체 통과, 실패 0

- [ ] **Step 2: 서버 실제 기동 확인**

```bash
./server.sh restart
sleep 5
./server.sh status
curl -s http://localhost:7788/v1/health | python3 -m json.tool
curl -s http://localhost:7777/health | python3 -m json.tool
```

Expected:
```json
{"status": "ok"}  // 7788
{"status": "ok"}  // 7777
```

- [ ] **Step 3: 실제 TTS 동작 확인**

```bash
curl -s -X POST http://localhost:7788/v1/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"MLX 기반 서버가 정상 동작합니다.","voice":"M2","lang":"ko","steps":8}' \
  -o /tmp/verify.wav
file /tmp/verify.wav && afplay /tmp/verify.wav
```

Expected: RIFF (WAV) 파일 생성 후 음성 재생

- [ ] **Step 4: 최종 커밋**

```bash
git add -A
git commit -m "feat: supertonic MLX 마이그레이션 완료 — Qwen 폴백 코드 전면 제거"
```

---

## 병렬 실행 순서

```
Task 1 (설치·다운로드)  ─┐
Task 2 (MLX 서버 작성)  ─┤─→ Task 5 (supervisor 교체)  ─→ Task 7 (통합 검증)
Task 3 (player.py)     ─┤
Task 4 (server.py)     ─┘─→ Task 6 (문서)
```

Task 1·2·3·4는 병렬 진행 가능.  
Task 5는 Task 2 완료 후.  
Task 6은 Task 3·4 완료 후.  
Task 7은 Task 5·6 모두 완료 후.
