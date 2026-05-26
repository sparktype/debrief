# TTS 상주 서버 — 모델 로딩과 추론을 동일한 워커 스레드에서 실행 (MLX GPU 스트림 요건)
import os
import glob
import re
import shutil
import subprocess
import tempfile
import datetime

os.environ["HF_HUB_OFFLINE"] = "1"

import queue
import threading
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel


def _log(level: str, message: str) -> None:
    """구조화 로그 출력 — [LEVEL] YYYY-MM-DD HH:MM:SS message 형식."""
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{level}] {ts} {message}", flush=True)


_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"

# 단일 워커 스레드 상태
_work_queue: queue.Queue = queue.Queue(maxsize=5)
_model_ready = threading.Event()
_model_error = threading.Event()
_model_error_message = ""
_worker_thread: Optional[threading.Thread] = None

# 한국어 TTS에서 발음이 부자연스러운 영문 기술 용어 → 한국어 발음 치환 사전
_TECH_PHONETICS: dict[str, str] = {
    # 프로토콜 / 통신
    "HTTP": "에이치티티피",
    "HTTPS": "에이치티티피에스",
    "gRPC": "지알피씨",
    "GRPC": "지알피씨",
    "RPC": "알피씨",
    "REST": "레스트",
    "WebSocket": "웹소켓",
    "WebSockets": "웹소켓",
    "TCP": "티씨피",
    "UDP": "유디피",
    "TLS": "티엘에스",
    "SSL": "에스에스엘",
    "DNS": "디엔에스",
    "IP": "아이피",
    "IPv4": "아이피브이사",
    "IPv6": "아이피브이육",
    # 인증 / 보안
    "API": "에이피아이",
    "SDK": "에스디케이",
    "JWT": "제이더블유티",
    "OAuth": "오오스",
    "SSO": "에스에스오",
    "RBAC": "알백",
    "MFA": "엠에프에이",
    # 클라우드 / 인프라
    "AWS": "에이더블유에스",
    "GCP": "지씨피",
    "K8s": "케이에이츠",
    "CI": "씨아이",
    "CD": "씨디",
    "DevOps": "데브옵스",
    "Docker": "도커",
    "Kubernetes": "쿠버네티스",
    "Helm": "헬름",
    "OTel": "오텔",
    "OTLP": "오티엘피",
    "Prometheus": "프로메테우스",
    "Grafana": "그라파나",
    "Kafka": "카프카",
    "Redis": "레디스",
    "Nginx": "엔진엑스",
    # AI / ML
    "LLM": "엘엘엠",
    "MLX": "엠엘엑스",
    "TTS": "티티에스",
    "STT": "에스티티",
    "AI": "에이아이",
    "ML": "엠엘",
    "MCP": "엠씨피",
    "RAG": "래그",
    "GPU": "지피유",
    "CPU": "씨피유",
    "TPU": "티피유",
    "OpenAI": "오픈에이아이",
    "ChatGPT": "챗지피티",
    "GPT": "지피티",
    "Claude": "클로드",
    # 데이터 형식
    "JSON": "제이슨",
    "YAML": "야믈",
    "CSV": "씨에스브이",
    "SQL": "에스큐엘",
    "NoSQL": "노에스큐엘",
    "XML": "엑스엠엘",
    "gzip": "지집",
    "Parquet": "파케이",
    # 서비스 / 플랫폼
    "GitHub": "깃허브",
    "GitLab": "깃랩",
    "Slack": "슬랙",
    "Linux": "리눅스",
    "macOS": "맥오에스",
    "iOS": "아이오에스",
    "Android": "안드로이드",
}

# 대소문자 무관 O(1) 조회를 위한 정규화 Map (key를 upper로 통일)
_TECH_PHONETICS_UPPER: dict[str, str] = {
    k.upper(): v for k, v in _TECH_PHONETICS.items()
}


def _preprocess_for_tts(text: str) -> str:
    """영문 기술 용어를 한국어 발음으로 치환 — lang_code=korean 시 발음 개선."""
    def _replace(m: re.Match) -> str:
        word = m.group(0)
        # 정규화 Map에서 O(1) 조회
        return _TECH_PHONETICS_UPPER.get(word.upper(), word)

    # 단어 경계 기준으로 치환 (한국어 조사 바로 앞 영문도 처리됨)
    return re.sub(r"[A-Za-z][A-Za-z0-9\-/\.]*", _replace, text)


def _tts_worker() -> None:
    """모델 로딩 + TTS 생성을 같은 스레드에서 처리 — MLX Metal 스트림 유지."""
    global _model_error_message
    try:
        from mlx_audio.tts.generate import generate_audio
        from mlx_audio.tts.utils import load_model

        _log("INFO", f"모델 로딩 중: {_MODEL_ID}")
        model = load_model(_MODEL_ID)
        _log("INFO", "모델 로딩 완료. 서버 준비.")
        _model_ready.set()
    except Exception as e:
        _model_error_message = str(e)
        _model_error.set()
        _log("ERROR", f"모델 로딩 실패: {e}")
        return

    while True:
        item = _work_queue.get()
        if item is None:  # 종료 신호
            break
        text, voice, lang_code, speed, instruct = item

        # 한국어 모드에서 영문 기술 용어 발음 보정
        if lang_code == "korean":
            processed = _preprocess_for_tts(text)
            if processed != text:
                _log("INFO", f"발음 보정: {text[:60]!r} → {processed[:60]!r}")
            text = processed

        tmpdir = tempfile.mkdtemp(prefix="vp_tts_")
        try:
            _log("INFO", f"재생 시작: {text[:40]!r} (speed={speed}x)")
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
                instruct=instruct if instruct else None,
            )
            files = sorted(glob.glob(f"{tmpdir}/*.wav"))
            if files:
                subprocess.run(["afplay", "-r", str(speed), files[0]], check=False)
            _log("INFO", "재생 완료")
        except Exception as e:
            _log("ERROR", f"재생 오류: {e}")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _worker_thread
    _worker_thread = threading.Thread(target=_tts_worker, daemon=True, name="tts-worker")
    _worker_thread.start()
    yield
    _work_queue.put(None)
    if _worker_thread:
        _worker_thread.join(timeout=5)
    _log("INFO", "서버 종료.")


app = FastAPI(title="Siren TTS Server", lifespan=lifespan)


class SpeakRequest(BaseModel):
    text: str
    voice: str = "Sohee"
    lang_code: str = "korean"
    speed: float = 1.2
    instruct: str = "밝고 활기차게 말해주세요"


@app.post("/speak", status_code=202)
async def speak(req: SpeakRequest):
    """TTS 재생 요청 — 즉시 202 반환, 워커 스레드에서 재생."""
    if not _model_ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    try:
        _work_queue.put_nowait((req.text, req.voice, req.lang_code, req.speed, req.instruct))
        return {"status": "accepted"}
    except queue.Full:
        return JSONResponse({"status": "busy"}, status_code=429)


@app.get("/health")
async def health():
    """서버 상태 확인 — 모델 로딩 실패면 503+error, 로딩 중이면 503+loading."""
    if _model_error.is_set():
        return JSONResponse(
            {"status": "error", "detail": _model_error_message},
            status_code=503,
        )
    if not _model_ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ok"}
