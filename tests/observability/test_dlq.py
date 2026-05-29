# tests/observability/test_dlq.py — DLQ SQLite 영속화 단위 테스트
import time
import pytest
from pathlib import Path

from hook_voice.observability.dlq import DLQStore, ReplayStatus


@pytest.fixture
def store(tmp_path: Path) -> DLQStore:
    s = DLQStore(db_path=tmp_path / "dlq_test.db")
    yield s
    s.close()


def test_push_returns_id(store):
    row_id = store.push(event_id="evt-001", failure_stage="tts_generate")
    assert isinstance(row_id, int)
    assert row_id >= 1


def test_push_multiple_increments_id(store):
    id1 = store.push(event_id="evt-001", failure_stage="ingest")
    id2 = store.push(event_id="evt-002", failure_stage="ingest")
    assert id2 > id1


def test_list_pending_initial(store):
    store.push(event_id="evt-001", failure_stage="ingest")
    store.push(event_id="evt-002", failure_stage="tts")
    pending = store.list_pending()
    assert len(pending) == 2
    assert all(e.replay_status == ReplayStatus.PENDING for e in pending)


def test_mark_replayed(store):
    row_id = store.push(event_id="evt-001", failure_stage="ingest")
    ok = store.mark_replayed(row_id)
    assert ok is True
    pending = store.list_pending()
    assert len(pending) == 0


def test_mark_replayed_sets_replayed_at(store):
    row_id = store.push(event_id="evt-001", failure_stage="ingest")
    store.mark_replayed(row_id)
    all_entries = store.list_all()
    entry = next(e for e in all_entries if e.id == row_id)
    assert entry.replayed_at is not None
    assert entry.replayed_at > entry.created_at - 1


def test_mark_failed(store):
    row_id = store.push(event_id="evt-001", failure_stage="ingest")
    ok = store.mark_failed(row_id, detail="timeout")
    assert ok is True
    all_entries = store.list_all()
    entry = next(e for e in all_entries if e.id == row_id)
    assert entry.replay_status == ReplayStatus.FAILED


def test_mark_skipped(store):
    row_id = store.push(event_id="evt-001", failure_stage="ingest")
    ok = store.mark_skipped(row_id)
    assert ok is True
    all_entries = store.list_all()
    entry = next(e for e in all_entries if e.id == row_id)
    assert entry.replay_status == ReplayStatus.SKIPPED


def test_mark_nonexistent_returns_false(store):
    ok = store.mark_replayed(99999)
    assert ok is False


def test_stats_empty(store):
    s = store.stats()
    assert s["total"] == 0
    assert s["pending"] == 0


def test_stats_after_push(store):
    store.push(event_id="e1", failure_stage="ingest")
    store.push(event_id="e2", failure_stage="tts")
    s = store.stats()
    assert s["total"] == 2
    assert s["pending"] == 2


def test_stats_mixed_statuses(store):
    id1 = store.push(event_id="e1", failure_stage="ingest")
    id2 = store.push(event_id="e2", failure_stage="tts")
    store.mark_replayed(id1)
    store.mark_failed(id2, "oops")
    s = store.stats()
    assert s["replayed"] == 1
    assert s["failed"] == 1
    assert s["pending"] == 0


def test_push_with_full_fields(store):
    row_id = store.push(
        event_id="evt-full",
        failure_stage="sink.deliver",
        failure_detail="connection refused",
        idempotency_key="idem-001",
        raw_text="GPU 메모리가 부족합니다",
        source="grafana",
        severity="critical",
        priority_score=90,
        metadata={"alert_id": "alert-123"},
    )
    entries = store.list_all()
    e = next(x for x in entries if x.id == row_id)
    assert e.source == "grafana"
    assert e.severity == "critical"
    assert e.priority_score == 90
    assert e.metadata == {"alert_id": "alert-123"}
    assert e.raw_text == "GPU 메모리가 부족합니다"


def test_list_all_returns_latest_first(store):
    store.push(event_id="e1", failure_stage="a")
    time.sleep(0.01)
    store.push(event_id="e2", failure_stage="b")
    entries = store.list_all()
    assert entries[0].event_id == "e2"
    assert entries[1].event_id == "e1"


def test_purge_older_than(store):
    id1 = store.push(event_id="e1", failure_stage="ingest")
    store.mark_replayed(id1)
    time.sleep(0.05)
    removed = store.purge_older_than(seconds=0.01)
    assert removed >= 1
    all_entries = store.list_all()
    assert not any(e.id == id1 for e in all_entries)


def test_purge_keeps_pending(store):
    store.push(event_id="e1", failure_stage="ingest")
    time.sleep(0.05)
    removed = store.purge_older_than(seconds=0.01)
    assert removed == 0  # pending는 삭제 안 됨
    assert len(store.list_pending()) == 1


def test_list_pending_respects_limit(store):
    for i in range(10):
        store.push(event_id=f"e{i}", failure_stage="ingest")
    pending = store.list_pending(limit=3)
    assert len(pending) == 3


def test_replay_status_enum_values():
    assert ReplayStatus.PENDING.value == "pending"
    assert ReplayStatus.REPLAYED.value == "replayed"
    assert ReplayStatus.FAILED.value == "failed"
    assert ReplayStatus.SKIPPED.value == "skipped"
