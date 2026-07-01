# hook_voice/delivery/priority_spool.py — HIGH/NORMAL/LOW 우선순위 기반 spool enqueue
from __future__ import annotations

import logging
import random
import shutil
import string
import time
from pathlib import Path

_log = logging.getLogger(__name__)

_SPOOL_DIR = Path("/tmp/tts-spool")
_NORMAL_MAX = 3
_NORMAL_TTL_SECS = 30


def enqueue_with_priority(
    audio_file: Path,
    spool_dir_or_speed: "Path | float | None" = None,
    speed: float = 1.0,
    priority_score: "int | None" = None,
    priority: str = "NORMAL",
    spool_dir: "Path | None" = None,
) -> "Path | None":
    """오디오 파일을 spool 디렉터리에 enqueue한다.

    두 가지 호출 방식 지원:

    [구 방식] priority_score 기반 (하위 호환):
        enqueue_with_priority(audio_file, spool_dir, speed=1.2, priority_score=40)
        → 파일명에 우선순위 점수를 인코딩. Path 반환.

    [신 방식] HIGH/NORMAL/LOW 정책:
        enqueue_with_priority(audio_path, speed=1.0, priority="NORMAL", spool_dir=None)
        HIGH: 기존 NORMAL/LOW를 모두 제거하고 즉시 삽입
        NORMAL: 최대 3개 유지, 넘으면 가장 오래된 것 제거
        LOW: 큐가 비어있을 때만 삽입
        → None 반환
    """
    # 호출 방식 판별: 두 번째 인자가 Path이거나 priority_score가 지정되면 구 방식
    if isinstance(spool_dir_or_speed, Path) or priority_score is not None:
        # --- 구 방식 (하위 호환) ---
        actual_spool: Path = spool_dir_or_speed  # type: ignore[assignment]
        actual_spool.mkdir(parents=True, exist_ok=True)
        rand = "".join(random.choices(string.ascii_lowercase + string.digits, k=5))
        ts = int(time.time() * 1000)
        speed_tag = str(round(speed * 100))
        priority_tag = f"{priority_score or 0:03d}"
        dest = actual_spool / f"{ts}_{rand}_{speed_tag}_{priority_tag}{audio_file.suffix}"
        audio_file.rename(dest)
        _log.debug("[PrioritySpool] enqueued %s priority=%d", dest.name, priority_score or 0)
        return dest

    # --- 신 방식 (HIGH/NORMAL/LOW) ---
    # spool_dir_or_speed가 float이면 speed로 사용
    actual_speed = spool_dir_or_speed if isinstance(spool_dir_or_speed, float) else speed
    spool = spool_dir or _SPOOL_DIR
    spool.mkdir(parents=True, exist_ok=True)

    existing = sorted(spool.glob("*.wav")) + sorted(spool.glob("*.mp3"))

    if priority == "HIGH":
        # NORMAL/LOW 파일 모두 제거
        for f in existing:
            try:
                f.unlink(missing_ok=True)
            except Exception:
                pass
    elif priority == "LOW":
        if existing:
            return None  # 큐에 파일이 있으면 LOW는 추가하지 않음
    else:  # NORMAL
        # TTL 만료 파일 먼저 제거 (30초 초과)
        now = time.time()
        for f in list(existing):
            try:
                if now - f.stat().st_mtime > _NORMAL_TTL_SECS:
                    f.unlink(missing_ok=True)
                    existing.remove(f)
            except Exception:
                pass
        if len(existing) >= _NORMAL_MAX:
            # 가장 오래된 파일 제거
            try:
                existing[0].unlink(missing_ok=True)
            except Exception:
                pass

    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    speed_tag = str(round(actual_speed * 100))
    dest = spool / f"{uid}_{speed_tag}{audio_file.suffix}"
    shutil.copy2(audio_file, dest)
    try:
        audio_file.unlink(missing_ok=True)
    except Exception:
        pass
    _log.debug("[PrioritySpool] enqueued %s priority=%s", dest.name, priority)
    return None
