# hook_voice/learning/stats_store.py — TTS 사용 통계를 로컬 JSONL 파일에 저장·조회·삭제
from __future__ import annotations

import json
import time
from pathlib import Path

_STATS_FILE: Path = Path.home() / ".local" / "share" / "chorus" / "usage_stats.jsonl"


def stats_file_path() -> Path:
    """현재 통계 파일 경로를 반환한다."""
    return _STATS_FILE


def record_playback(
    agent_type: str,
    mode: str,
    priority: str,
    completed: bool,
    duration_secs: float,
) -> None:
    """TTS 재생 이벤트 한 건을 JSONL 파일에 추가한다.

    agent_type: 에이전트 타입 (예: "builder", "reviewer", "default")
    mode: 발화 모드 ("full" | "summary_only" | "earcon_only")
    priority: 우선순위 ("HIGH" | "NORMAL" | "LOW")
    completed: True이면 끝까지 재생, False이면 중단
    duration_secs: 재생 시도 시간 (초)
    """
    entry = {
        "ts": round(time.time(), 3),
        "agent_type": agent_type,
        "mode": mode,
        "priority": priority,
        "completed": completed,
        "duration_secs": round(duration_secs, 3),
    }
    _STATS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with _STATS_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def load_stats(limit: int = 500) -> list[dict]:
    """통계 파일에서 최근 limit개 항목을 반환한다.

    파일이 없으면 빈 리스트를 반환한다.
    """
    if not _STATS_FILE.exists():
        return []
    lines = _STATS_FILE.read_text(encoding="utf-8").splitlines()
    recent = lines[-limit:] if len(lines) > limit else lines
    result = []
    for line in recent:
        line = line.strip()
        if not line:
            continue
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def clear_stats() -> int:
    """통계 파일을 삭제하고 삭제된 항목 수를 반환한다."""
    if not _STATS_FILE.exists():
        return 0
    count = len(_STATS_FILE.read_text(encoding="utf-8").splitlines())
    _STATS_FILE.unlink()
    return count
