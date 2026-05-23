# TTS 상주 서버 — 모델 로딩과 추론을 동일한 워커 스레드에서 실행 (MLX GPU 스트림 요건)
import os
import glob
import subprocess
import tempfile

os.environ["HF_HUB_OFFLINE"] = "1"

import queue
import threading
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel

_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"

# 단일 워커 스레드 상태
_work_queue: queue.Queue = queue.Queue(maxsize=1)
_model_ready = threading.Event()
_worker_thread: Optional[threading.Thread] = None


def _tts_worker() -> None:
    """모델 로딩 + TTS 생성을 같은 스레드에서 처리 — MLX Metal 스트림 유지."""
    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model

    print(f"[TTS Server] 모델 로딩 중: {_MODEL_ID}", flush=True)
    model = load_model(_MODEL_ID)
    print("[TTS Server] 모델 로딩 완료. 서버 준비.", flush=True)
    _model_ready.set()

    while True:
        item = _work_queue.get()
        if item is None:  # 종료 신호
            break
        text, voice, lang_code, speed = item
        tmpdir = tempfile.mkdtemp(prefix="siren_tts_")
        try:
            print(f"[TTS Server] 재생 시작: {text[:40]!r} (speed={speed}x)", flush=True)
            # speed=1.0 고정 — Qwen3-TTS는 speed!=1.0 시 최적화 경로가 꺼짐
            # 재생 속도는 afplay -r 로 후처리
            generate_audio(
                text=text,
                model=model,
                voice=voice,
                lang_code=lang_code,
                speed=1.0,
                play=False,
                output_path=tmpdir,
                save=True,
            )
            files = sorted(glob.glob(f"{tmpdir}/*.wav"))
            if files:
                subprocess.run(["afplay", "-r", str(speed), files[0]], check=False)
            print("[TTS Server] 재생 완료", flush=True)
        except Exception as e:
            print(f"[TTS Server] 재생 오류: {e}", flush=True)
        finally:
            for f in glob.glob(f"{tmpdir}/*"):
                os.unlink(f)
            os.rmdir(tmpdir)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _worker_thread
    _worker_thread = threading.Thread(target=_tts_worker, daemon=True, name="tts-worker")
    _worker_thread.start()
    yield
    _work_queue.put(None)
    if _worker_thread:
        _worker_thread.join(timeout=5)
    print("[TTS Server] 서버 종료.", flush=True)


app = FastAPI(title="Siren TTS Server", lifespan=lifespan)


class SpeakRequest(BaseModel):
    text: str
    voice: str = "Sohee"
    lang_code: str = "korean"
    speed: float = 1.2


@app.post("/speak", status_code=202)
async def speak(req: SpeakRequest):
    """TTS 재생 요청 — 즉시 202 반환, 워커 스레드에서 재생."""
    if not _model_ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    try:
        _work_queue.put_nowait((req.text, req.voice, req.lang_code, req.speed))
        return {"status": "accepted"}
    except queue.Full:
        return JSONResponse({"status": "busy"}, status_code=429)


@app.get("/health")
async def health():
    """서버 상태 확인 — 모델 로딩 전이면 503."""
    if not _model_ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ok"}
