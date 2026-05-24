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


def sanitize_for_speech(text: str) -> str:
    text = re.sub(r"[^\w\s,.!?。:]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


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
