# hook_voice/delivery/earcon.py — 4종 Earcon 생성 및 spool 삽입
from __future__ import annotations

import asyncio
import logging
import math
import struct
import tempfile
import time
from enum import Enum
from pathlib import Path

_log = logging.getLogger(__name__)

# 샘플 레이트
_SAMPLE_RATE = 22050
# 음향 감쇠 계수 (인덱스 = 음 번호)
_ACOUSTIC_DECAY = [1.0, 0.85, 0.70]


class EarconType(Enum):
    CRITICAL = "critical"   # 하강 3음 (D5→B4→G4)
    HIGH = "high"           # 상승 2음 (A4→C5)
    RESOLVED = "resolved"   # 상승 3음 (G4→B4→D5)
    SUMMARY = "summary"     # 중립 2음 (C5→C5 반박자)


# 음표 주파수 (Hz)
_NOTE_FREQ = {
    "G4": 392.00, "A4": 440.00, "B4": 493.88,
    "C5": 523.25, "D5": 587.33,
}

_EARCON_NOTES: dict[EarconType, list[str]] = {
    EarconType.CRITICAL: ["D5", "B4", "G4"],
    EarconType.HIGH:     ["A4", "C5"],
    EarconType.RESOLVED: ["G4", "B4", "D5"],
    EarconType.SUMMARY:  ["C5", "C5"],
}

_NOTE_DURATION = 0.12  # 음 하나당 초


def _sine_wave(freq: float, duration: float, amplitude: float, sample_rate: int) -> bytes:
    n_samples = int(sample_rate * duration)
    frames: list[int] = []
    for i in range(n_samples):
        t = i / sample_rate
        val = amplitude * math.sin(2 * math.pi * freq * t)
        # 어택/릴리즈 엔벨로프 (10% 페이드)
        fade = min(1.0, min(i, n_samples - i) / (n_samples * 0.1 + 1))
        frames.append(int(val * fade * 32767))
    return struct.pack(f"<{n_samples}h", *frames)


def _build_wav(pcm_frames: bytes, sample_rate: int) -> bytes:
    n_bytes = len(pcm_frames)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", n_bytes + 36, b"WAVE",
        b"fmt ", 16, 1, 1,
        sample_rate, sample_rate * 2, 2, 16,
        b"data", n_bytes,
    )
    return header + pcm_frames


def generate_earcon(earcon_type: EarconType, volume: float = 0.4) -> bytes:
    """earcon WAV 바이트를 생성한다. 오디오 라이브러리 없이 순수 Python으로 구현."""
    notes = _EARCON_NOTES[earcon_type]
    pcm = b""
    for i, note_name in enumerate(notes):
        freq = _NOTE_FREQ[note_name]
        amplitude = volume * _ACOUSTIC_DECAY[min(i, len(_ACOUSTIC_DECAY) - 1)]
        pcm += _sine_wave(freq, _NOTE_DURATION, amplitude, _SAMPLE_RATE)
    return _build_wav(pcm, _SAMPLE_RATE)


async def enqueue_earcon(
    earcon_type: EarconType,
    spool_dir: Path,
    priority_score: int = 150,
    volume: float = 0.4,
) -> Path | None:
    """earcon WAV를 spool 디렉터리에 최우선 순위로 삽입한다."""
    try:
        spool_dir.mkdir(exist_ok=True)
        wav_bytes = await asyncio.get_event_loop().run_in_executor(
            None, generate_earcon, earcon_type, volume
        )
        uid = f"{int(time.time() * 1000):016d}"
        speed_tag = "100"  # earcon은 속도 조절 없음
        dest = spool_dir / f"{uid}_{speed_tag}_earcon_{earcon_type.value}.wav"
        dest.write_bytes(wav_bytes)
        return dest
    except Exception as e:
        _log.warning("[Earcon] 생성 실패 type=%s: %s", earcon_type.value, e)
        return None


def earcon_for_priority(priority_score: int) -> EarconType | None:
    """priority_score에 맞는 Earcon 타입 반환. 낮은 우선순위는 None."""
    if priority_score >= 85:
        return EarconType.CRITICAL
    if priority_score >= 65:
        return EarconType.HIGH
    return None
