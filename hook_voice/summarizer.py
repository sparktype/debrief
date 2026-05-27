# hook_voice/summarizer.py
# LLM 기반 텍스트 요약기 — HMG Hub API 사용, 실패 시 규칙 기반 폴백
import re
from .llm_client import chat_completion, DEFAULT_MODEL

_SUMMARY_SYSTEM = (
    "주어진 텍스트의 핵심 결론이나 중요한 내용을 1~3문장으로 요약하세요. "
    "코드·마크다운 기호 없이 자연스러운 한국어 평문으로 작성합니다."
)
_ONE_LINER_SYSTEM = "작업 결과를 한 문장(25자 이내)으로 요약하세요. 마침표·특수기호 없이, 간결하게."


def strip_markdown(text: str) -> str:
    text = re.sub(r"```[\s\S]*?```", "[코드 생략]", text)
    text = re.sub(r"`[^`]+`", "", text)
    text = re.sub(r"^\|.+$", "", text, flags=re.MULTILINE)
    text = re.sub(r"#{1,6} (.+)", r"\1", text)
    text = re.sub(r"^[-*]{3,}$", "", text, flags=re.MULTILINE)
    text = re.sub(r"\*{1,3}([^*\n]+)\*{1,3}", r"\1", text)
    text = re.sub(r"_([^_\n]+)_", r"\1", text)
    text = re.sub(r"\n+", " ", text)
    return text.strip()


# ── Expression Tag 자동 선택 ────────────────────────────────────────────────

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


def select_expression_tag(one_liner: str, category: str) -> str:
    """one_liner 내용과 에이전트 카테고리 기반으로 Expression Tag를 선택한다.
    반환값: 태그 문자열 (e.g. '<breath>') 또는 빈 문자열."""
    c = one_liner
    if _CRITICAL_RE.search(c):
        return "<cry>"
    if _SURPRISE_RE.search(c):
        return "<gasp>"
    if _CAUTION_RE.search(c):
        return "<clear_throat>"
    if _REGRET_RE.search(c):
        return "<sniff>"
    if _NEGATIVE_RE.search(c):
        return "<sigh>"
    if category == "tester" and _SUCCESS_RE.search(c):
        return "<laugh>"
    if _DISCOVERY_RE.search(c) and category in ("explorer", "planner", "reviewer"):
        return "<hmm>"
    if category == "ops" and _ROUTINE_RE.search(c):
        return "<yawn>"
    return _ROLE_DEFAULT_TAGS.get(category, "<breath>")


# ── Expression Tags sanitize 보존 ────────────────────────────────────────────

# Supertonic Expression Tags — sanitize 시 보존
_EXPR_TAG_RE = re.compile(
    r"<(?:breath|laugh|sigh|clear_throat|hmm|cough|sniff|gasp|yawn|cry)>",
    re.IGNORECASE,
)


def sanitize_for_speech(text: str) -> str:
    tags: list[str] = []

    def _save(m: re.Match) -> str:
        tags.append(m.group())
        return f"__ETAG{len(tags) - 1}__"

    text = _EXPR_TAG_RE.sub(_save, text)
    text = re.sub(r"[^\w\s,.!?。:]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    for i, tag in enumerate(tags):
        text = text.replace(f"__ETAG{i}__", tag)
    return text


def _fallback(text: str, sentence_count: int = 3) -> str:
    cleaned = strip_markdown(text)
    if not cleaned:
        return ""
    sentences = [s.strip() for s in re.split(r"(?<=[.!?。])\s*", cleaned) if len(s.strip()) > 1]
    return " ".join(sentences[-sentence_count:]) if sentences else cleaned


async def extract_summary(text: str, model: str = DEFAULT_MODEL) -> str:
    if not text.strip():
        return ""
    result = await chat_completion(
        messages=[
            {"role": "system", "content": _SUMMARY_SYSTEM},
            {"role": "user", "content": strip_markdown(text)},
        ],
        model=model,
        max_completion_tokens=200,
        temperature=0.3,
    )
    return result or _fallback(text)


async def extract_one_liner(text: str, model: str = DEFAULT_MODEL) -> str:
    if not text.strip():
        return ""
    result = await chat_completion(
        messages=[
            {"role": "system", "content": _ONE_LINER_SYSTEM},
            {"role": "user", "content": strip_markdown(text)[:2000]},
        ],
        model=model,
        max_completion_tokens=60,
        temperature=0.3,
    )
    return sanitize_for_speech(result or _fallback(text, 1))
