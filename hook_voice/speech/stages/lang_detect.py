# hook_voice/speech/stages/lang_detect.py — 언어 감지 (전역 <5ms + sliding window)
from __future__ import annotations

import re
from collections import deque
from ..pipeline import SpeechContext

_KO_RE = re.compile(r"[가-힣ᄀ-ᇿ㄰-㆏]")
_EN_RE = re.compile(r"[A-Za-z]")

_WINDOW_N = 10     # sliding window 최대 샘플 수
_WINDOW_T = 30.0   # sliding window 최대 시간(초) — context-notes 참조

# sliding window: (timestamp, language)
_window: deque[tuple[float, str]] = deque(maxlen=_WINDOW_N)


def _detect(text: str) -> tuple[str, float]:
    """텍스트의 언어와 신뢰도를 반환한다. 전역 규칙 기반, <5ms."""
    total = len(text.replace(" ", ""))
    if total == 0:
        return "ko", 1.0
    ko = len(_KO_RE.findall(text))
    en = len(_EN_RE.findall(text))
    ko_ratio = ko / total
    en_ratio = en / total
    if ko_ratio > 0.5:
        return "ko", min(1.0, ko_ratio + 0.1)
    if en_ratio > 0.5:
        return "en", min(1.0, en_ratio + 0.1)
    if ko > 0 and en > 0:
        return "mixed", max(ko_ratio, en_ratio)
    return "ko", 0.6  # 숫자·특수문자만


def lang_detect_stage(ctx: SpeechContext) -> SpeechContext:
    lang, conf = _detect(ctx.text)
    ctx.language = lang
    ctx.language_confidence = conf
    return ctx
