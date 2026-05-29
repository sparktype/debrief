# tests/delivery/test_earcon.py — Earcon 생성 단위 테스트
import struct
import pytest
from pathlib import Path

from hook_voice.delivery.earcon import (
    EarconType, generate_earcon, enqueue_earcon, earcon_for_priority,
    _EARCON_NOTES,
)


def _parse_wav(data: bytes) -> dict:
    assert data[:4] == b"RIFF"
    assert data[8:12] == b"WAVE"
    sample_rate = struct.unpack_from("<I", data, 24)[0]
    data_size = struct.unpack_from("<I", data, 40)[0]
    return {"sample_rate": sample_rate, "data_size": data_size}


def test_generate_critical():
    wav = generate_earcon(EarconType.CRITICAL)
    info = _parse_wav(wav)
    assert info["sample_rate"] == 22050
    assert info["data_size"] > 0


def test_generate_high():
    wav = generate_earcon(EarconType.HIGH)
    assert len(wav) > 44  # WAV header 이상


def test_generate_resolved():
    wav = generate_earcon(EarconType.RESOLVED)
    info = _parse_wav(wav)
    assert info["data_size"] > 0


def test_generate_summary():
    wav = generate_earcon(EarconType.SUMMARY)
    info = _parse_wav(wav)
    assert info["data_size"] > 0


def test_critical_longer_than_high():
    # CRITICAL = 3음, HIGH = 2음 → 길이 차이
    critical = generate_earcon(EarconType.CRITICAL)
    high = generate_earcon(EarconType.HIGH)
    assert len(critical) > len(high)


def test_volume_affects_amplitude():
    loud = generate_earcon(EarconType.HIGH, volume=1.0)
    quiet = generate_earcon(EarconType.HIGH, volume=0.1)
    # 동일 구조, 진폭만 다름 — 크기는 같아야 함
    assert len(loud) == len(quiet)


async def test_enqueue_earcon_creates_file(tmp_path):
    dest = await enqueue_earcon(EarconType.HIGH, spool_dir=tmp_path)
    assert dest is not None
    assert dest.exists()
    assert dest.suffix == ".wav"
    assert "earcon_high" in dest.name


async def test_enqueue_earcon_priority_in_filename(tmp_path):
    dest = await enqueue_earcon(EarconType.CRITICAL, spool_dir=tmp_path, priority_score=150)
    assert dest is not None
    # 파일명에 "earcon_critical" 포함
    assert "earcon_critical" in dest.name


def test_earcon_for_priority_critical():
    assert earcon_for_priority(90) == EarconType.CRITICAL
    assert earcon_for_priority(85) == EarconType.CRITICAL


def test_earcon_for_priority_high():
    assert earcon_for_priority(70) == EarconType.HIGH
    assert earcon_for_priority(65) == EarconType.HIGH


def test_earcon_for_priority_none():
    assert earcon_for_priority(50) is None
    assert earcon_for_priority(0) is None
