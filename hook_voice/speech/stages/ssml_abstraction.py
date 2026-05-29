# hook_voice/speech/stages/ssml_abstraction.py — SSML 태그 생성 및 expression tag 결합
from __future__ import annotations

import re
from ..pipeline import SpeechContext

# 기존 summarizer.py의 expression tag 로직을 이 단계로 통합
_CRITICAL_RE  = re.compile(r"치명|장애|다운|크리티컬")
_SURPRISE_RE  = re.compile(r"예상치\s*못|의외|갑자기|놀랍|충격")
_CAUTION_RE   = re.compile(r"주의|경고|위험|삭제|되돌릴|강제|초기화")
_REGRET_RE    = re.compile(r"아쉽|미완성|부족|개선.*필요")
_NEGATIVE_RE  = re.compile(r"실패|에러|오류|문제|충돌|이슈|버그|안됨|불가")
_SUCCESS_RE   = re.compile(r"통과|성공|완벽|완료")
_DISCOVERY_RE = re.compile(r"발견|분석|흥미|패턴|탐색")
_ROUTINE_RE   = re.compile(r"정상|이상없음|문제없음")

_ROLE_DEFAULT_TAGS: dict[str, str] = {
    "reviewer":   "<breath>",
    "planner":    "<breath>",
    "tester":     "<breath>",
    "explorer":   "<hmm>",
    "guardian":   "<clear_throat>",
    "builder":    "",
    "optimizer":  "",
    "ops":        "<cough>",
    "specialist": "<breath>",
    "default":    "<breath>",
}


def select_expression_tag(text: str, category: str = "default") -> str:
    """텍스트 내용과 에이전트 카테고리 기반 Expression Tag 선택."""
    if _CRITICAL_RE.search(text):
        return "<cry>"
    if _SURPRISE_RE.search(text):
        return "<gasp>"
    if _CAUTION_RE.search(text):
        return "<clear_throat>"
    if _REGRET_RE.search(text):
        return "<sniff>"
    if _NEGATIVE_RE.search(text):
        return "<sigh>"
    if category == "tester" and _SUCCESS_RE.search(text):
        return "<laugh>"
    if _DISCOVERY_RE.search(text) and category in ("explorer", "planner", "reviewer"):
        return "<hmm>"
    if category == "ops" and _ROUTINE_RE.search(text):
        return "<yawn>"
    return _ROLE_DEFAULT_TAGS.get(category, "<breath>")


def ssml_abstraction_stage(ctx: SpeechContext) -> SpeechContext:
    """segments를 SSML 발화 단위로 결합하고 ctx.ssml에 저장한다.

    Edge TTS / Supertonic 의 SSML 지원 수준에 맞춰 단순 구조 유지.
    expression tag는 ctx.metadata['category']에서 읽어온다.
    """
    category = ctx.metadata.get("category", "default")
    tag = select_expression_tag(ctx.text, category)

    body = " ".join(ctx.segments) if ctx.segments else ctx.text
    prefix = f"{tag} " if tag else ""
    ctx.ssml = f"{prefix}{body}"
    return ctx
