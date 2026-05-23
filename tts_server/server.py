# TTS 상주 서버 — 모델을 한 번 로딩해 메모리에 유지하며 /speak 요청 처리
import os

os.environ["HF_HUB_OFFLINE"] = "1"

import threading
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, BackgroundTasks
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# --- 전역 상태 ---
_model = None
_play_lock = threading.Lock()
_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"


# --- lifespan: 시작 시 모델 로딩 ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model
    print(f"[TTS Server] 모델 로딩 중: {_MODEL_ID}", flush=True)
    from mlx_audio.tts.utils import load_model
    _model = load_model(_MODEL_ID)
    print("[TTS Server] 모델 로딩 완료. 서버 준비.", flush=True)
    yield
    # 종료 시 정리 (필요 시 추가)
    _model = None
    print("[TTS Server] 서버 종료.", flush=True)


app = FastAPI(title="Siren TTS Server", lifespan=lifespan)


# --- 요청 스키마 ---
class SpeakRequest(BaseModel):
    text: str
    voice: str = "Sohee"
    lang_code: str = "Auto"


# --- 재생 작업 (백그라운드 스레드) ---
def _do_speak(text: str, voice: str, lang_code: str) -> None:
    """Lock 획득 후 TTS 생성 + 재생. 이미 재생 중이면 즉시 반환."""
    acquired = _play_lock.acquire(blocking=False)
    if not acquired:
        print("[TTS Server] 재생 중 — 새 요청 무시", flush=True)
        return
    try:
        from mlx_audio.tts.generate import generate_audio
        print(f"[TTS Server] 재생 시작: {text[:40]!r}", flush=True)
        generate_audio(
            text=text,
            model=_model,
            voice=voice,
            lang_code=lang_code,
            play=True,
            output_path="/tmp",
        )
        print("[TTS Server] 재생 완료", flush=True)
    except Exception as e:
        print(f"[TTS Server] 재생 오류: {e}", flush=True)
    finally:
        _play_lock.release()


# --- 엔드포인트 ---
@app.post("/speak", status_code=202)
async def speak(req: SpeakRequest, background_tasks: BackgroundTasks):
    """TTS 재생 요청 — 즉시 202 반환, 백그라운드에서 재생."""
    background_tasks.add_task(
        lambda: threading.Thread(
            target=_do_speak,
            args=(req.text, req.voice, req.lang_code),
            daemon=True,
        ).start()
    )
    return {"status": "accepted"}


@app.get("/health")
async def health():
    """서버 상태 확인."""
    return {"status": "ok"}
