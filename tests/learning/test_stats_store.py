# 통계 저장소 단위 테스트
import json
from pathlib import Path
import pytest


def test_record_playback_appends_jsonl(tmp_path, monkeypatch):
    """record_playback이 JSONL 파일에 한 줄을 추가한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback(
        agent_type="builder", mode="full", priority="NORMAL",
        completed=True, duration_secs=3.5,
    )

    lines = (tmp_path / "stats.jsonl").read_text().splitlines()
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert entry["agent_type"] == "builder"
    assert entry["completed"] is True
    assert entry["duration_secs"] == pytest.approx(3.5, abs=0.01)
    assert "ts" in entry


def test_record_playback_multiple_appends(tmp_path, monkeypatch):
    """여러 번 호출하면 여러 줄이 추가된다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    for i in range(3):
        stats_store.record_playback("reviewer", "full", "HIGH", True, float(i))

    lines = (tmp_path / "stats.jsonl").read_text().splitlines()
    assert len(lines) == 3


def test_load_stats_returns_list(tmp_path, monkeypatch):
    """load_stats가 저장된 항목을 dict 리스트로 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback("planner", "summary_only", "NORMAL", False, 1.0)
    stats_store.record_playback("builder", "full", "NORMAL", True, 2.0)

    result = stats_store.load_stats()
    assert len(result) == 2
    assert result[0]["agent_type"] == "planner"
    assert result[1]["agent_type"] == "builder"


def test_load_stats_empty_file(tmp_path, monkeypatch):
    """파일이 없으면 빈 리스트를 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "nonexistent.jsonl")

    result = stats_store.load_stats()
    assert result == []


def test_clear_stats_deletes_file(tmp_path, monkeypatch):
    """clear_stats가 파일을 삭제하고 삭제된 항목 수를 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    stats_store.record_playback("guardian", "full", "NORMAL", True, 5.0)
    stats_store.record_playback("guardian", "full", "NORMAL", False, 1.0)

    deleted = stats_store.clear_stats()
    assert deleted == 2
    assert not (tmp_path / "stats.jsonl").exists()


def test_clear_stats_no_file(tmp_path, monkeypatch):
    """파일이 없어도 0을 반환하고 에러가 없다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "nofile.jsonl")

    deleted = stats_store.clear_stats()
    assert deleted == 0


def test_load_stats_respects_limit(tmp_path, monkeypatch):
    """limit 파라미터가 최근 N개만 반환한다."""
    from hook_voice.learning import stats_store
    monkeypatch.setattr(stats_store, "_STATS_FILE", tmp_path / "stats.jsonl")

    for i in range(10):
        stats_store.record_playback("tester", "full", "NORMAL", True, float(i))

    result = stats_store.load_stats(limit=3)
    assert len(result) == 3
    # 가장 최근 3개 (마지막 줄부터)
    assert result[-1]["duration_secs"] == pytest.approx(9.0, abs=0.01)
