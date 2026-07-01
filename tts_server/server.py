# FastAPI 단일 서버 — STT·메트릭·DLQ + Supertonic MLX TTS (포트 7777)
import asyncio
import concurrent.futures
import datetime
import io
import os
import re
import signal

os.environ["HF_HUB_OFFLINE"] = "1"

from contextlib import asynccontextmanager
from pathlib import Path

import soundfile as sf
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from hook_voice.config import load_config as _load_voice_config
from hook_voice.observability.metrics import get_registry as _get_metrics
from hook_voice.observability.dlq import get_dlq_store as _get_dlq_store
from hook_voice.speech_listener import SpeechListener

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


# MLX Metal GPU 전용 단일 워커 스레드 — 모델 로드와 추론을 같은 스레드에서 실행
_mlx_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
_model: object | None = None
_stt_listener: SpeechListener | None = None


def _log(level: str, message: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{level}] {ts} {message}", flush=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model, _stt_listener, _mlx_executor
    # 재진입 시(테스트 등) 종료된 executor를 새로 생성한다
    try:
        _mlx_executor.submit(lambda: None)  # 실행 가능 여부 확인
    except RuntimeError:
        _mlx_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
    loop = asyncio.get_event_loop()

    def _load_model():
        from supertonic_mlx import SupertonicMLX
        import logging
        model = SupertonicMLX(MODEL_DIR)
        try:
            style = model.get_voice_style("M1")
            model.synthesize("워밍업.", "ko", style, total_step=2)
        except Exception as e:
            logging.getLogger(__name__).warning("워밍업 실패 (무시): %s", e)
        return model

    _model = await loop.run_in_executor(_mlx_executor, _load_model)
    _log("INFO", "SupertonicMLX 모델 로드 완료")

    _voice_cfg = _load_voice_config()
    if _voice_cfg.stt.enabled:
        _stt_listener = SpeechListener(_voice_cfg.stt)
        _log("INFO", f"[STT] SpeechListener 초기화 (model={_voice_cfg.stt.model})")

    yield

    if _stt_listener is not None and _stt_listener.state == "recording":
        await _stt_listener.toggle()
    _mlx_executor.shutdown(wait=False)
    _model = None
    _log("INFO", "서버 종료.")


app = FastAPI(title="Chorus Server", lifespan=lifespan)


SPOOL_DIR_SERVER = Path("/tmp/tts-spool")


# ── 공통 헬스 ────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    queue_files = (
        list(SPOOL_DIR_SERVER.glob("*.wav")) + list(SPOOL_DIR_SERVER.glob("*.mp3"))
    ) if SPOOL_DIR_SERVER.exists() else []
    return {
        "status": "ok",
        "model_loaded": _model is not None,
        "queue_depth": len(queue_files),
        "stt_enabled": _stt_listener is not None,
    }


# ── 재생 제어 ─────────────────────────────────────────────────────────────────


@app.post("/interrupt")
async def interrupt_playback():
    """현재 afplay 재생을 SIGTERM → SIGKILL 2단계로 즉시 중단한다."""
    pid_file = SPOOL_DIR_SERVER / ".player.pid"
    if not pid_file.exists():
        return {"status": "not_playing", "pid": None}
    try:
        pid = int(pid_file.read_text().strip())
    except (ValueError, OSError):
        pid_file.unlink(missing_ok=True)
        return {"status": "not_playing", "pid": None}
    try:
        os.kill(pid, signal.SIGTERM)
        # 0.3초 대기 후 미종료 시 SIGKILL
        await asyncio.sleep(0.3)
        try:
            os.kill(pid, 0)  # 프로세스 존재 확인
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # SIGTERM으로 이미 종료됨
        pid_file.unlink(missing_ok=True)
        return {"status": "interrupted", "pid": pid}
    except ProcessLookupError:
        pid_file.unlink(missing_ok=True)
        return {"status": "not_playing", "pid": pid}
    except PermissionError as e:
        return {"status": "error", "detail": str(e)}


@app.get("/playback/status")
async def playback_status():
    """현재 재생 상태와 스풀 큐 깊이를 반환한다."""
    pid_file = SPOOL_DIR_SERVER / ".player.pid"
    is_playing = False
    current_pid = None
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 0)  # 프로세스 존재 확인
            is_playing = True
            current_pid = pid
        except (ValueError, ProcessLookupError, OSError):
            pid_file.unlink(missing_ok=True)
    queue_files = list(SPOOL_DIR_SERVER.glob("*.wav")) + list(SPOOL_DIR_SERVER.glob("*.mp3"))
    return {
        "is_playing": is_playing,
        "pid": current_pid,
        "queue_depth": len(queue_files),
    }


# ── TTS ─────────────────────────────────────────────────────────────────────

class TTSRequest(BaseModel):
    text: str
    lang: str = "ko"
    voice: str = "M1"
    steps: int = 8
    speed: float = 1.05
    response_format: str = "wav"


@app.get("/v1/health")
async def v1_health():
    if _model is None:
        raise HTTPException(503, "모델 로딩 중")
    return {"status": "ok"}


@app.post("/v1/tts")
async def tts(req: TTSRequest):
    if _model is None:
        raise HTTPException(503, "모델 로딩 중")
    processed = _preprocess(req.text)
    loop = asyncio.get_event_loop()

    def _sync_synthesize() -> bytes:
        style = _model.get_voice_style(req.voice)
        wav, _ = _model.synthesize(
            processed, req.lang, style,
            total_step=req.steps, speed=req.speed,
        )
        buf = io.BytesIO()
        sf.write(buf, wav[0], _model.sample_rate, format="WAV")
        return buf.getvalue()

    wav_bytes = await loop.run_in_executor(_mlx_executor, _sync_synthesize)
    return Response(wav_bytes, media_type="audio/wav")


# ── STT ─────────────────────────────────────────────────────────────────────

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


# ── 메트릭 / DLQ ─────────────────────────────────────────────────────────────

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
