# hook_voice/delivery/priority_spool.py — priority_score 기반 spool enqueue 래퍼
from __future__ import annotations

import logging
import random
import string
import time
from pathlib import Path

_log = logging.getLogger(__name__)


def enqueue_with_priority(
    audio_file: Path,
    spool_dir: Path,
    speed: float,
    priority_score: int = 0,
) -> Path:
    """오디오 파일을 priority_score를 파일명에 인코딩해 spool 디렉터리에 추가한다.

    파일명 형식: {ts}_{rand}_{speed}_{priority}.{ext}
    - ts: 밀리초 타임스탬프 (낮을수록 오래됨)
    - priority: priority_score (TTS Player가 역순 정렬 가능하도록 0패딩)

    TTS Player가 우선순위를 지원하지 않는 경우에도 타임스탬프 순으로 재생되므로
    기존 동작과 하위 호환된다.
    """
    spool_dir.mkdir(parents=True, exist_ok=True)
    rand = "".join(random.choices(string.ascii_lowercase + string.digits, k=5))
    ts = int(time.time() * 1000)
    speed_tag = str(round(speed * 100))
    priority_tag = f"{priority_score:03d}"
    dest = spool_dir / f"{ts}_{rand}_{speed_tag}_{priority_tag}{audio_file.suffix}"
    audio_file.rename(dest)
    _log.debug("[PrioritySpool] enqueued %s priority=%d", dest.name, priority_score)
    return dest
