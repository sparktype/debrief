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
