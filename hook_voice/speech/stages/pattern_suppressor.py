# hook_voice/speech/stages/pattern_suppressor.py — URL·마크다운·코드블록 억제
from __future__ import annotations

import re
from ..pipeline import SpeechContext

_CODE_BLOCK_RE = re.compile(r"```[\s\S]*?```")
_INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
_URL_RE = re.compile(r"https?://\S+|www\.\S+")
_TABLE_RE = re.compile(r"^\|.+\|$", re.MULTILINE)
_HEADING_RE = re.compile(r"^#{1,6}\s+", re.MULTILINE)
_BOLD_ITALIC_RE = re.compile(r"\*{1,3}([^*\n]+)\*{1,3}|_([^_\n]+)_")
_HR_RE = re.compile(r"^[-*]{3,}$", re.MULTILINE)


def _strip(text: str) -> str:
    text = _CODE_BLOCK_RE.sub("[코드 생략]", text)
    text = _URL_RE.sub("[링크 생략]", text)
    text = _TABLE_RE.sub("", text)
    text = _HEADING_RE.sub("", text)
    text = _BOLD_ITALIC_RE.sub(lambda m: m.group(1) or m.group(2), text)
    text = _HR_RE.sub("", text)
    text = _INLINE_CODE_RE.sub("", text)
    text = re.sub(r"\n+", " ", text)
    return text.strip()


def pattern_suppressor_stage(ctx: SpeechContext) -> SpeechContext:
    ctx.text = _strip(ctx.text)
    ctx.segments = [_strip(s) for s in ctx.segments if _strip(s)]
    return ctx
