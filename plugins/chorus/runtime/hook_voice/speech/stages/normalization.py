# hook_voice/speech/stages/normalization.py — 숫자·단위·특수문자 정규화
from __future__ import annotations

import re
from ..pipeline import SpeechContext

# Expression Tags — 이 단계에서 보존 (sanitize 전)
_EXPR_TAG_RE = re.compile(
    r"<(?:breath|laugh|sigh|clear_throat|hmm|cough|sniff|gasp|yawn|cry)>",
    re.IGNORECASE,
)

_UNIT_MAP = {
    "ms": "밀리초", "μs": "마이크로초", "ns": "나노초", "s": "초",
    "KB": "킬로바이트", "MB": "메가바이트", "GB": "기가바이트", "TB": "테라바이트",
    "kB/s": "초당 킬로바이트", "MB/s": "초당 메가바이트",
    "%": "퍼센트",
}
_UNIT_RE = re.compile(
    r"(\d+(?:\.\d+)?)\s*(" + "|".join(re.escape(u) for u in sorted(_UNIT_MAP, key=len, reverse=True)) + r")\b"
)

_SPECIAL_RE = re.compile(r"[→←↑↓⇒⇐≥≤±©®™…—–]")
_SPECIAL_MAP = {
    "→": "에서", "←": "로", "↑": "증가", "↓": "감소",
    "⇒": "결과", "⇐": "입력", "≥": "이상", "≤": "이하",
    "±": "플러스마이너스", "©": "", "®": "", "™": "",
    "…": "", "—": " ", "–": " ",
}


def _replace_unit(m: re.Match) -> str:
    num, unit = m.group(1), m.group(2)
    return f"{num} {_UNIT_MAP.get(unit, unit)}"


def _normalize(text: str) -> str:
    # Expression Tag 보존
    tags: list[str] = []
    def _save(m: re.Match) -> str:
        tags.append(m.group())
        return f"__ETAG{len(tags)-1}__"
    text = _EXPR_TAG_RE.sub(_save, text)

    text = _UNIT_RE.sub(_replace_unit, text)
    for ch, rep in _SPECIAL_MAP.items():
        text = text.replace(ch, rep)
    text = re.sub(r"\s+", " ", text).strip()

    for i, tag in enumerate(tags):
        text = text.replace(f"__ETAG{i}__", tag)
    return text


def normalization_stage(ctx: SpeechContext) -> SpeechContext:
    ctx.text = _normalize(ctx.text)
    ctx.segments = [_normalize(s) for s in ctx.segments]
    return ctx
