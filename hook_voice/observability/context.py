# correlation_id 기반 HookContext 생성 및 seq 영속화 모듈
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

_SEQ_FILE = Path.home() / ".local" / "share" / "voice-persona" / "hook_seq.txt"
_UNKNOWN_SESSION = "00000000"


@dataclass
class HookContext:
    session_id: str
    seq: int
    correlation_id: str


def _read_seq(full_sid: str) -> int:
    try:
        if _SEQ_FILE.exists():
            parts = _SEQ_FILE.read_text().strip().split(":")
            if len(parts) == 2 and parts[0] == full_sid:
                return int(parts[1])
    except Exception:
        pass
    return 0


def _write_seq(full_sid: str, seq: int) -> None:
    try:
        _SEQ_FILE.parent.mkdir(parents=True, exist_ok=True)
        _SEQ_FILE.write_text(f"{full_sid}:{seq}")
    except Exception:
        pass


def get_or_create_context() -> HookContext:
    """CLAUDE_CODE_SESSION_ID 환경변수에서 세션 ID를 읽어 HookContext를 생성한다."""
    raw_sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    full_sid = raw_sid if raw_sid else _UNKNOWN_SESSION
    short_sid = full_sid[:8]

    seq = _read_seq(full_sid) + 1
    _write_seq(full_sid, seq)

    return HookContext(
        session_id=full_sid,
        seq=seq,
        correlation_id=f"{short_sid}:{seq:04d}",
    )
