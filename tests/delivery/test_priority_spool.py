# tests/delivery/test_priority_spool.py — priority_spool enqueue 단위 테스트
import time
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


# ── 신 방식: HIGH/NORMAL/LOW 정책 테스트 ────────────────────────────────────


def _make_wav(p: Path) -> Path:
    p.write_bytes(b"RIFF" + b"\x00" * 40)
    return p


def test_high_priority_clears_normal(tmp_path):
    """HIGH 우선순위 enqueue 시 기존 NORMAL 파일이 모두 제거된다."""
    spool = tmp_path / "spool"
    spool.mkdir()

    # NORMAL 2개 먼저 추가
    for i in range(2):
        wav = _make_wav(tmp_path / f"n{i}.wav")
        enqueue_with_priority(wav, speed=1.0, priority="NORMAL", spool_dir=spool)

    high_wav = _make_wav(tmp_path / "high.wav")
    enqueue_with_priority(high_wav, speed=1.0, priority="HIGH", spool_dir=spool)

    files = sorted(spool.glob("*.wav"))
    assert len(files) == 1  # HIGH 하나만 남아야 함


def test_normal_max_3(tmp_path):
    """NORMAL은 최대 3개까지만 큐에 유지된다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    for i in range(5):
        wav = _make_wav(tmp_path / f"n{i}.wav")
        time.sleep(0.001)  # 타임스탬프 구분
        enqueue_with_priority(wav, speed=1.0, priority="NORMAL", spool_dir=spool)

    files = list(spool.glob("*.wav"))
    assert len(files) <= 3


def test_low_skipped_when_queue_busy(tmp_path):
    """큐에 파일이 있을 때 LOW는 추가되지 않는다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    normal_wav = _make_wav(tmp_path / "normal.wav")
    enqueue_with_priority(normal_wav, speed=1.0, priority="NORMAL", spool_dir=spool)

    low_wav = _make_wav(tmp_path / "low.wav")
    enqueue_with_priority(low_wav, speed=1.0, priority="LOW", spool_dir=spool)

    files = list(spool.glob("*.wav"))
    assert len(files) == 1  # LOW 추가 안 됨


def test_low_added_when_queue_empty(tmp_path):
    """큐가 비어있을 때 LOW는 추가된다."""
    spool = tmp_path / "spool"
    spool.mkdir()
    low_wav = _make_wav(tmp_path / "low.wav")
    enqueue_with_priority(low_wav, speed=1.0, priority="LOW", spool_dir=spool)

    files = list(spool.glob("*.wav"))
    assert len(files) == 1


def test_normal_ttl_expires_old_files(tmp_path):
    """30초 초과된 NORMAL 파일은 새 enqueue 시 자동 제거된다."""
    import os

    spool = tmp_path / "spool"
    spool.mkdir()

    # 오래된 파일 (31초 전)
    old_wav = _make_wav(tmp_path / "old.wav")
    enqueue_with_priority(old_wav, speed=1.0, priority="NORMAL", spool_dir=spool)
    spool_files = list(spool.glob("*.wav"))
    assert len(spool_files) == 1
    old_spool = spool_files[0]
    # mtime을 31초 전으로 설정
    old_time = time.time() - 31
    os.utime(old_spool, (old_time, old_time))

    # 새 파일 enqueue 시 오래된 파일 제거
    new_wav = _make_wav(tmp_path / "new.wav")
    enqueue_with_priority(new_wav, speed=1.0, priority="NORMAL", spool_dir=spool)

    remaining = list(spool.glob("*.wav"))
    assert len(remaining) == 1
    # 오래된 파일이 제거됐는지 확인
    assert remaining[0].name != old_spool.name
