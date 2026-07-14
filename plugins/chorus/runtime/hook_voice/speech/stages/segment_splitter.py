# hook_voice/speech/stages/segment_splitter.py — 문장 단위 분할
from __future__ import annotations

import re
from ..pipeline import SpeechContext

_SPLIT_RE = re.compile(r"(?<=[.!?。\n])\s+")


def segment_splitter_stage(ctx: SpeechContext) -> SpeechContext:
    """텍스트를 문장 단위로 분할해 ctx.segments에 저장한다."""
    parts = _SPLIT_RE.split(ctx.text.strip())
    ctx.segments = [p.strip() for p in parts if p.strip()]
    if not ctx.segments:
        ctx.segments = [ctx.text] if ctx.text.strip() else []
    return ctx
