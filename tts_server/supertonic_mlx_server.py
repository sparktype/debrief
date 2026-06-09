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
