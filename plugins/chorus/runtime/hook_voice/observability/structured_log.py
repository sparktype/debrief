# JSON Lines 형식 구조화 로그를 stderr에 출력하는 모듈
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

from .context import HookContext

_LEVEL_MAP = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}


def _current_level() -> int:
    return _LEVEL_MAP.get(os.environ.get("VOICE_LOG_LEVEL", "INFO").upper(), 20)


def log_event(
    event: str,
    ctx: HookContext,
    extra: dict[str, Any] | None = None,
    level: str = "INFO",
) -> None:
    """JSON Lines 형식으로 stderr에 구조화 로그를 출력한다."""
    if _LEVEL_MAP.get(level.upper(), 20) < _current_level():
        return

    now = time.time()
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now))
    ms = int(now * 1000) % 1000

    record: dict[str, Any] = {
        "ts": f"{ts}.{ms:03d}Z",
        "level": level.upper(),
        "correlation_id": ctx.correlation_id,
        "event": event,
    }
    if extra:
        safe_extra = {k: v for k, v in extra.items() if k not in record}
        record.update(safe_extra)

    try:
        print(json.dumps(record, ensure_ascii=False), file=sys.stderr)
    except Exception:
        pass
