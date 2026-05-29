# hook_voice/speech/stages/identifier_normalizer.py — snake_case/CamelCase/UUID/IP 정규화
from __future__ import annotations

import re
from ..pipeline import SpeechContext

# UUID: 8-4-4-4-12 형식
_UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)
# IPv4
_IPV4_RE = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b")
# snake_case: 두 개 이상의 단어를 포함한 경우만
_SNAKE_RE = re.compile(r"\b([a-z][a-z0-9]*)(?:_[a-z][a-z0-9]*)+\b")
# CamelCase: 대문자로 시작, 내부에 대문자 포함
_CAMEL_RE = re.compile(r"\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b")


def _snake_to_words(m: re.Match) -> str:
    words = m.group().split("_")
    return " ".join(words)


def _camel_to_words(m: re.Match) -> str:
    # CamelCase → 공백 삽입 (예: UserService → User Service)
    s = re.sub(r"([A-Z])", r" \1", m.group()).strip()
    return s


def identifier_normalizer_stage(ctx: SpeechContext) -> SpeechContext:
    text = ctx.text
    text = _UUID_RE.sub("[고유ID]", text)
    text = _IPV4_RE.sub("[IP주소]", text)
    text = _SNAKE_RE.sub(_snake_to_words, text)
    text = _CAMEL_RE.sub(_camel_to_words, text)
    ctx.text = text
    ctx.segments = [seg for seg in (
        _CAMEL_RE.sub(_camel_to_words, _SNAKE_RE.sub(_snake_to_words,
            _IPV4_RE.sub("[IP주소]", _UUID_RE.sub("[고유ID]", seg))))
        for seg in ctx.segments
    )]
    return ctx
