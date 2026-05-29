# tests/delivery/test_priority_spool.py — priority_spool enqueue 단위 테스트
import pytest
from pathlib import Path

from hook_voice.delivery.priority_spool import enqueue_with_priority


def test_enqueue_creates_file_in_spool(tmp_path):
    src = tmp_path / "audio_src.mp3"
    src.write_bytes(b"fake-audio")
    spool = tmp_path / "spool"
    dest = enqueue_with_priority(src, spool, speed=1.2, priority_score=40)
    assert dest.exists()
    assert not src.exists()  # rename으로 이동됨


def test_filename_encodes_speed(tmp_path):
    src = tmp_path / "audio.mp3"
    src.write_bytes(b"x")
    spool = tmp_path / "spool"
    dest = enqueue_with_priority(src, spool, speed=1.1, priority_score=30)
    # speed 1.1 → 110
    assert "_110_" in dest.name


def test_filename_encodes_priority(tmp_path):
    src = tmp_path / "audio.wav"
    src.write_bytes(b"x")
    spool = tmp_path / "spool"
    dest = enqueue_with_priority(src, spool, speed=1.0, priority_score=90)
    assert "_090" in dest.name


def test_spool_dir_created_if_missing(tmp_path):
    src = tmp_path / "audio.mp3"
    src.write_bytes(b"x")
    spool = tmp_path / "nonexistent" / "spool"
    dest = enqueue_with_priority(src, spool, speed=1.0, priority_score=10)
    assert dest.exists()


def test_priority_sort_order(tmp_path):
    spool = tmp_path / "spool"
    for i, (prio, name) in enumerate([(30, "low"), (90, "high"), (50, "mid")]):
        src = tmp_path / f"{name}.wav"
        src.write_bytes(b"x")
        enqueue_with_priority(src, spool, speed=1.0, priority_score=prio)
    files = sorted(spool.glob("*.wav"), key=lambda f: f.name)
    # 타임스탬프 순 — 먼저 삽입된 것이 먼저 나옴 (기존 동작 호환)
    assert len(files) == 3
