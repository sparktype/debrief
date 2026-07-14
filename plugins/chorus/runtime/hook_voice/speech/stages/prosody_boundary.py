# hook_voice/speech/stages/prosody_boundary.py — 언어 경계 break time 주입
from __future__ import annotations

import re
from ..pipeline import SpeechContext

# 언어 경계별 break time (ms) — context-notes 참조
_SAME_SCRIPT_BREAK = 30       # 동일 스크립트 경계 (20-40ms)
_SIMILAR_SCRIPT_BREAK = 10    # 유사 스크립트 (숫자 경계, 0-20ms)
_DIFF_SCRIPT_BREAK = 90       # 이종 스크립트 (60-120ms)

_KO_RE = re.compile(r"[가-힣]")
_EN_RE = re.compile(r"[A-Za-z]")


def _script_of(ch: str) -> str:
    if _KO_RE.match(ch):
        return "ko"
    if _EN_RE.match(ch):
        return "en"
    if ch.isdigit():
        return "num"
    return "other"


def _break_tag(ms: int) -> str:
    return f'<break time="{ms}ms"/>'


def _inject_breaks(text: str) -> str:
    """스크립트 전환 지점에 SSML break 태그를 삽입한다."""
    result: list[str] = []
    prev_script = ""
    for i, ch in enumerate(text):
        script = _script_of(ch)
        if prev_script and script != prev_script and ch.strip():
            if prev_script == "num" or script == "num":
                result.append(_break_tag(_SIMILAR_SCRIPT_BREAK))
            elif {prev_script, script} == {"ko", "en"}:
                result.append(_break_tag(_DIFF_SCRIPT_BREAK))
            else:
                result.append(_break_tag(_SAME_SCRIPT_BREAK))
        result.append(ch)
        if ch.strip():
            prev_script = script
    return "".join(result)


def prosody_boundary_stage(ctx: SpeechContext) -> SpeechContext:
    # ctx.text는 SSML 미지원 엔진(EdgeTTS 등)이 그대로 쓰므로 변경하지 않음
    # break 태그는 ctx.segments → ctx.ssml 경로에서만 사용
    ctx.segments = [_inject_breaks(s) for s in ctx.segments]
    return ctx
