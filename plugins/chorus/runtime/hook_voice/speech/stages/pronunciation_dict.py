# hook_voice/speech/stages/pronunciation_dict.py — Trie 기반 IT 용어 발음 치환
from __future__ import annotations

from ..pipeline import SpeechContext
from ..pronunciation_db import get_default_db


def pronunciation_dict_stage(ctx: SpeechContext) -> SpeechContext:
    db = get_default_db()
    ctx.text = db.apply(ctx.text)
    ctx.segments = [db.apply(s) for s in ctx.segments]
    return ctx
