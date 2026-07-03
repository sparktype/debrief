# hook_voice/assist/recommend.py — 프롬프트 분석 기반 voiceMode 추천 모듈
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path

from ..llm_client import chat_completion, DEFAULT_MODEL

_log = logging.getLogger(__name__)

# 쿨다운 파일 기반 영속화: 각 hook이 새 subprocess이므로 in-memory dict는 무의미
_RECOMMEND_COOLDOWN_PATH = Path("~/.local/share/chorus/recommend-cooldowns.json").expanduser()
_RECOMMEND_COOLDOWN_SEC = 300.0


def _load_recommend_cooldowns() -> dict[str, float]:
    """파일에서 쿨다운 타임스탬프를 읽어온다. 파일 없으면 {}."""
    try:
        if _RECOMMEND_COOLDOWN_PATH.exists():
            return json.loads(_RECOMMEND_COOLDOWN_PATH.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {}


def _save_recommend_cooldowns(cooldowns: dict[str, float]) -> None:
    """쿨다운 타임스탬프를 파일에 atomic write로 저장한다."""
    try:
        _RECOMMEND_COOLDOWN_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = _RECOMMEND_COOLDOWN_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(cooldowns), encoding="utf-8")
        tmp.replace(_RECOMMEND_COOLDOWN_PATH)
    except Exception:
        pass


def _is_recommend_in_cooldown(value: str) -> bool:
    """파일 기반 쿨다운을 확인한다. 300초 이내면 True."""
    cooldowns = _load_recommend_cooldowns()
    last = cooldowns.get(value, 0.0)
    return (time.time() - last) < _RECOMMEND_COOLDOWN_SEC


def _set_recommend_cooldown(value: str) -> None:
    """파일에 현재 시각을 쿨다운으로 저장한다."""
    cooldowns = _load_recommend_cooldowns()
    cooldowns[value] = time.time()
    _save_recommend_cooldowns(cooldowns)

_RECOMMEND_SYSTEM = """\
당신은 개발자의 Claude Code 입력 프롬프트를 분석해 TTS 음성 모드를 추천하는 어시스턴트입니다.
아래 입력과 컨텍스트를 보고 가장 적합한 음성 모드를 추천하세요.

음성 모드 기준:
- focus: 분석·리뷰·긴 계획 작업 (상세 설명이 필요한 경우)
- quiet: 반복 실패·노이즈가 많은 세션 (간결한 피드백이 필요한 경우)
- verbose: 짧은 대화형 설정 작업 (즉각적인 피드백이 필요한 경우)

반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.
{"kind": "mode", "value": "<focus|quiet|verbose>", "reason": "<한 문장 이유>"}
"""


@dataclass
class Recommendation:
    """단일 추천 결과."""
    kind: str   # 추천 종류 (예: "mode")
    value: str  # 추천 값 (예: "focus")
    reason: str # 추천 이유 (한 문장)


def _parse_recommendation(raw: str) -> Recommendation | None:
    """LLM 응답 문자열을 Recommendation으로 파싱한다."""
    try:
        data = json.loads(raw)
        kind = data.get("kind", "")
        value = data.get("value", "")
        reason = data.get("reason", "")
        if not kind or not value:
            return None
        return Recommendation(kind=kind, value=value, reason=reason)
    except Exception:
        return None


def _is_in_cooldown(value: str) -> bool:
    """쿨다운 내 동일 value면 True를 반환한다 (파일 기반)."""
    return _is_recommend_in_cooldown(value)


async def recommend_prompt_assist(
    prompt: str,
    transcript_context: str,
    stats: dict,
    model: str = DEFAULT_MODEL,
    timeout_ms: int = 2500,
) -> Recommendation | None:
    """프롬프트 의도를 분석해 voiceMode 추천을 반환한다.

    LLM 실패 또는 timeout 시 None을 반환한다 (fail-open).
    동일 value의 추천은 300초 쿨다운 내 억제한다.
    """
    if not prompt.strip():
        return None

    user_content = f"프롬프트: {prompt[:400]}"
    if transcript_context:
        user_content += f"\n\n최근 컨텍스트:\n{transcript_context[:600]}"

    timeout_sec = timeout_ms / 1000.0
    try:
        raw = await asyncio.wait_for(
            chat_completion(
                messages=[
                    {"role": "system", "content": _RECOMMEND_SYSTEM},
                    {"role": "user", "content": user_content},
                ],
                model=model,
                max_completion_tokens=100,
                temperature=0.2,
            ),
            timeout=timeout_sec,
        )
    except asyncio.TimeoutError:
        _log.warning("recommend_prompt_assist: LLM timeout (%.1fs)", timeout_sec)
        return None
    except Exception as exc:
        _log.warning("recommend_prompt_assist: LLM 오류 (%s)", type(exc).__name__)
        return None

    rec = _parse_recommendation(raw)
    if rec is None:
        return None

    if _is_in_cooldown(rec.value):
        _log.debug("recommend_prompt_assist: 쿨다운 내 동일 추천 억제 (value=%s)", rec.value)
        return None

    _set_recommend_cooldown(rec.value)
    return rec
