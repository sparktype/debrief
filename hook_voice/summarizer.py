# hook_voice/summarizer.py
# LLM 기반 텍스트 요약기 — HMG Hub API 사용, 실패 시 규칙 기반 폴백
import re
from .llm_client import chat_completion, DEFAULT_MODEL

_SUMMARY_SYSTEM = (
    "주어진 텍스트의 핵심 결론이나 중요한 내용을 1~3문장으로 요약하세요. "
    "코드·마크다운 기호 없이 자연스러운 한국어 평문으로 작성합니다."
)
_ONE_LINER_SYSTEM = "작업 결과를 한 문장(25자 이내)으로 요약하세요. 마침표·특수기호 없이, 간결하게."

_ONE_LINER_WITH_TAG_SYSTEM = """\
개발 작업 결과를 분석해 JSON으로 반환하세요.

1. one_liner: 핵심 결과를 25자 이내 경어체 한 문장으로 요약 (마침표·특수기호 없이)
2. tag: 내용의 감정에 가장 어울리는 Expression Tag — 아래 중 하나만 선택
   laugh        성공·완료·칭찬·개선·긍정적 결과
   sigh         실패·오류·에러·부정적 결과
   gasp         예상치 못한 발견·놀람
   cry          치명적 장애·시스템 다운
   sniff        아쉬움·미완성·개선 필요
   clear_throat 경고·중요 공지·주의 사항
   hmm          분석 중·탐색·생각 중
   yawn         반복적 정상 상태·루틴
   cough        경미한 주의·미세한 문제
   breath       일반 상황 (위 중 해당 없음)

반드시 JSON만 반환: {"one_liner": "...", "tag": "laugh"}
"""
_RETOUCH_SYSTEM = (
    "다음 텍스트를 한국어 TTS 발화에 적합하게 정제하세요.\n"
    "1. 마크다운 기호(** * # ` [] | > —) 완전 제거\n"
    "2. 영문 IT 용어를 한국어 발음으로 변환 (API→에이피아이, GPU→지피유, HTTP→에이치티티피, LLM→엘엘엠)\n"
    "3. 코드 블록·URL은 '[코드 생략]' / '[링크 생략]'으로\n"
    "4. 특수 기호(→ ← ≥ ± © ® ™ …) 제거 또는 한국어로\n"
    "5. <breath> <laugh> <sigh> <clear_throat> <hmm> <cough> <sniff> <gasp> <yawn> <cry> 태그는 그대로 보존\n"
    "6. 의미 변경 없이 정제만 — 새 내용 추가 금지\n"
    "출력: 정제된 텍스트만, 설명 없이"
)


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


# ── 코드 블록 자동 축약 ─────────────────────────────────────────────────────

_CODE_BLOCK_RE = re.compile(r"```[\s\S]*?```")


def has_heavy_code(text: str) -> bool:
    """코드 블록 비율이 40% 초과인지 판단한다."""
    if not text:
        return False
    code_chars = sum(len(m.group()) for m in _CODE_BLOCK_RE.finditer(text))
    return code_chars / max(len(text), 1) > 0.4


def summarize_with_code_hint(text: str) -> str:
    """코드 비율 높은 텍스트를 '[N줄 코드]' 힌트 포함 문자열로 변환한다.
    코드 비율이 낮으면 strip_markdown 결과를 반환한다."""
    if not text:
        return ""
    if not has_heavy_code(text):
        return strip_markdown(text)
    # 코드 줄 수 계산
    code_lines = sum(
        len(m.group().splitlines()) - 2  # ``` 제거
        for m in _CODE_BLOCK_RE.finditer(text)
    )
    code_lines = max(code_lines, 1)
    non_code = _CODE_BLOCK_RE.sub("", text).strip()
    brief = strip_markdown(non_code)[:40] if non_code else ""
    prefix = f"{brief} " if brief else ""
    return f"{prefix}[{code_lines}줄 코드]와 함께 완료됐습니다"


def chunk_for_tts(text: str, max_chars: int = 80) -> list[str]:
    """문장 경계에서 텍스트를 분할한다.

    max_chars 이하로 청크를 구성하며, 단일 문장이 max_chars를 초과하면 그대로 유지한다.
    """
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]
    # 문장 분리
    sentences = [s.strip() for s in re.split(r"(?<=[.!?。])\s+", text) if s.strip()]
    if not sentences:
        return [text]
    chunks: list[str] = []
    current = ""
    for sent in sentences:
        candidate = f"{current} {sent}".strip() if current else sent
        if len(candidate) <= max_chars:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = sent
    if current:
        chunks.append(current)
    return chunks if chunks else [text]


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
    "reviewer":   "<breath>",       # M2 deep calm — 신중하게 시작
    "planner":    "<hmm>",          # M1 upbeat — 아이디어를 떠올리며
    "builder":    "<breath>",       # M4 gentle — 작업 시작 전
    "tester":     "<breath>",       # F2 cheerful — 결과 발표 전
    "explorer":   "<hmm>",          # F3 professional — 분석하며 발견
    "optimizer":  "<hmm>",          # M3 authoritative — 분석 후 결론
    "guardian":   "<breath>",       # M5 warm storytelling — 따뜻하게 시작
    "ops":        "<clear_throat>", # F4 crisp confident — 주목을 요청하며
    "specialist": "<breath>",       # F5 gentle — 친절하게 시작
    "default":    "<breath>",       # F1 calm — 자연스럽게
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


async def retouch_for_speech(text: str, model: str = DEFAULT_MODEL) -> str:
    """LLM으로 TTS 발화용 텍스트 정제 — 마크다운 제거, IT 용어 발음 변환."""
    if not text.strip():
        return text
    try:
        result = await chat_completion(
            messages=[
                {"role": "system", "content": _RETOUCH_SYSTEM},
                {"role": "user", "content": text},
            ],
            model=model,
            max_completion_tokens=300,
            temperature=0.0,
        )
        return sanitize_for_speech(result) if result else sanitize_for_speech(text)
    except Exception:
        return sanitize_for_speech(text)


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
    return sanitize_for_speech(result or _fallback(text))


def rule_one_liner(text: str, max_chars: int = 25) -> str:
    """LLM 없이 규칙 기반으로 한 줄 요약 — 서브에이전트 발화용."""
    cleaned = strip_markdown(text)
    sentences = [s.strip() for s in re.split(r"(?<=[.!?。])\s*", cleaned) if len(s.strip()) > 1]
    candidate = sentences[-1] if sentences else cleaned
    if len(candidate) > max_chars:
        candidate = candidate[:max_chars].rsplit(" ", 1)[0]
    return sanitize_for_speech(candidate)


_VALID_TAGS = frozenset({"breath","laugh","sigh","clear_throat","hmm","cough","sniff","gasp","yawn","cry"})


async def extract_one_liner_with_tag(
    text: str, category: str, model: str = DEFAULT_MODEL
) -> tuple[str, str]:
    """LLM으로 한 줄 요약과 감정 태그를 동시에 생성한다. 실패 시 규칙 기반 폴백."""
    import json
    if not text.strip():
        return "", _ROLE_DEFAULT_TAGS.get(category, "<breath>")
    try:
        result = await chat_completion(
            messages=[
                {"role": "system", "content": _ONE_LINER_WITH_TAG_SYSTEM},
                {"role": "user", "content": strip_markdown(text)[:2000]},
            ],
            model=model,
            max_completion_tokens=80,
            temperature=0.0,
        )
        if result:
            raw = result.strip()
            # JSON 블록 추출
            if "```" in raw:
                m = re.search(r"\{.*\}", raw, re.DOTALL)
                raw = m.group() if m else raw
            data = json.loads(raw)
            one_liner = sanitize_for_speech(str(data.get("one_liner", "")))
            tag_name  = str(data.get("tag", "breath")).strip().lower()
            tag = f"<{tag_name}>" if tag_name in _VALID_TAGS else "<breath>"
            return one_liner or sanitize_for_speech(_fallback(text, 1)), tag
    except (json.JSONDecodeError, AttributeError, KeyError):
        pass
    except Exception:
        import logging
        logging.getLogger(__name__).warning("extract_one_liner_with_tag 예외", exc_info=True)
    one_liner = sanitize_for_speech(_fallback(text, 1))
    return one_liner, select_expression_tag(one_liner, category)


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
