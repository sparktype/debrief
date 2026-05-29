# hook_voice/observability/dlq.py — SQLite 기반 Dead Letter Queue 영속화
from __future__ import annotations

import json
import logging
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Generator

_log = logging.getLogger(__name__)

_DEFAULT_DB_PATH = Path.home() / ".local" / "share" / "voice-persona" / "dlq.db"


class ReplayStatus(str, Enum):
    PENDING = "pending"
    REPLAYED = "replayed"
    FAILED = "failed"
    SKIPPED = "skipped"


@dataclass
class DLQEntry:
    id: int | None
    event_id: str
    idempotency_key: str
    failure_stage: str
    failure_detail: str
    raw_text: str
    source: str
    severity: str
    priority_score: int
    replay_status: ReplayStatus
    created_at: float
    replayed_at: float | None
    metadata: dict


class DLQStore:
    """SQLite 기반 DLQ 영속화. 스레드 안전(check_same_thread=False + 외부 직렬화 가정)."""

    def __init__(self, db_path: Path | None = None) -> None:
        self._path = db_path or _DEFAULT_DB_PATH
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self._path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._bootstrap()

    def _bootstrap(self) -> None:
        self._conn.executescript("""
            CREATE TABLE IF NOT EXISTS dlq (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id        TEXT NOT NULL,
                idempotency_key TEXT NOT NULL DEFAULT '',
                failure_stage   TEXT NOT NULL,
                failure_detail  TEXT NOT NULL DEFAULT '',
                raw_text        TEXT NOT NULL DEFAULT '',
                source          TEXT NOT NULL DEFAULT '',
                severity        TEXT NOT NULL DEFAULT 'info',
                priority_score  INTEGER NOT NULL DEFAULT 0,
                replay_status   TEXT NOT NULL DEFAULT 'pending',
                created_at      REAL NOT NULL,
                replayed_at     REAL,
                metadata        TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS dlq_status_idx ON dlq (replay_status);
            CREATE INDEX IF NOT EXISTS dlq_created_idx ON dlq (created_at);
        """)
        self._conn.commit()

    @contextmanager
    def _tx(self) -> Generator[sqlite3.Connection, None, None]:
        try:
            yield self._conn
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise

    def push(
        self,
        *,
        event_id: str,
        failure_stage: str,
        failure_detail: str = "",
        idempotency_key: str = "",
        raw_text: str = "",
        source: str = "",
        severity: str = "info",
        priority_score: int = 0,
        metadata: dict | None = None,
    ) -> int:
        with self._tx() as conn:
            cur = conn.execute(
                """
                INSERT INTO dlq
                  (event_id, idempotency_key, failure_stage, failure_detail,
                   raw_text, source, severity, priority_score,
                   replay_status, created_at, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                """,
                (
                    event_id, idempotency_key, failure_stage, failure_detail,
                    raw_text, source, severity, priority_score,
                    time.time(), json.dumps(metadata or {}),
                ),
            )
            row_id = cur.lastrowid
        _log.debug("[DLQ] pushed event_id=%s stage=%s id=%d", event_id, failure_stage, row_id)
        return row_id

    def list_pending(self, limit: int = 50) -> list[DLQEntry]:
        rows = self._conn.execute(
            "SELECT * FROM dlq WHERE replay_status = 'pending' ORDER BY created_at LIMIT ?",
            (limit,),
        ).fetchall()
        return [self._row_to_entry(r) for r in rows]

    def list_all(self, limit: int = 100) -> list[DLQEntry]:
        rows = self._conn.execute(
            "SELECT * FROM dlq ORDER BY created_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [self._row_to_entry(r) for r in rows]

    def mark_replayed(self, entry_id: int) -> bool:
        with self._tx() as conn:
            cur = conn.execute(
                "UPDATE dlq SET replay_status = 'replayed', replayed_at = ? WHERE id = ?",
                (time.time(), entry_id),
            )
        return cur.rowcount > 0

    def mark_failed(self, entry_id: int, detail: str = "") -> bool:
        with self._tx() as conn:
            cur = conn.execute(
                "UPDATE dlq SET replay_status = 'failed', failure_detail = ? WHERE id = ?",
                (detail, entry_id),
            )
        return cur.rowcount > 0

    def mark_skipped(self, entry_id: int) -> bool:
        with self._tx() as conn:
            cur = conn.execute(
                "UPDATE dlq SET replay_status = 'skipped' WHERE id = ?",
                (entry_id,),
            )
        return cur.rowcount > 0

    def stats(self) -> dict:
        row = self._conn.execute("""
            SELECT
                COUNT(*) FILTER (WHERE replay_status = 'pending')  AS pending,
                COUNT(*) FILTER (WHERE replay_status = 'replayed') AS replayed,
                COUNT(*) FILTER (WHERE replay_status = 'failed')   AS failed,
                COUNT(*) FILTER (WHERE replay_status = 'skipped')  AS skipped,
                COUNT(*) AS total
            FROM dlq
        """).fetchone()
        return dict(row) if row else {}

    def purge_older_than(self, seconds: float) -> int:
        cutoff = time.time() - seconds
        with self._tx() as conn:
            cur = conn.execute(
                "DELETE FROM dlq WHERE created_at < ? AND replay_status != 'pending'",
                (cutoff,),
            )
        return cur.rowcount

    def close(self) -> None:
        self._conn.close()

    @staticmethod
    def _row_to_entry(row: sqlite3.Row) -> DLQEntry:
        return DLQEntry(
            id=row["id"],
            event_id=row["event_id"],
            idempotency_key=row["idempotency_key"],
            failure_stage=row["failure_stage"],
            failure_detail=row["failure_detail"],
            raw_text=row["raw_text"],
            source=row["source"],
            severity=row["severity"],
            priority_score=row["priority_score"],
            replay_status=ReplayStatus(row["replay_status"]),
            created_at=row["created_at"],
            replayed_at=row["replayed_at"],
            metadata=json.loads(row["metadata"]),
        )


# 모듈 싱글톤
_store: DLQStore | None = None


def get_dlq_store(db_path: Path | None = None) -> DLQStore:
    global _store
    if _store is None:
        _store = DLQStore(db_path)
    return _store
