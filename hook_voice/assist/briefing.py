# hook_voice/assist/briefing.py — LLM 응답 브리핑 및 명령 실패 설명 생성 모듈
from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass

from ..llm_client import chat_completion, DEFAULT_MODEL
from ..summarizer import (
    extract_summary,
    has_heavy_code,
    sanitize_for_speech,
    strip_markdown,
    summarize_with_code_hint,
)

_log = logging.getLogger(__name__)

_BRIEFING_SYSTEM = """\
당신은 AI 코딩 어시스턴트(Claude)의 응답을 음성으로 브리핑하는 역할입니다.
아래 내용을 한국어로 10~12초 분량(약 100~130자)의 경어체 발화 텍스트로 요약하세요.

브리핑 구조 (순서 준수):
1. 결론 — 이번 작업에서 가장 중요한 결과 한 문장
2. 변경 파일/액션 — 수정하거나 실행한 핵심 파일·명령 (없으면 생략)
3. 검증 증거 — 테스트 통과·빌드 성공·오류 해결 등 확인 근거 (없으면 생략)
4. 다음 액션/블로커 — 권장 다음 단계 또는 남은 과제 (없으면 생략)

출력 규칙:
- 마크다운 금지 (**, *, #, `, --- 등)
- 코드 블록 금지 (``` 또는 인라인 코드 금지)
- 경어체 사용 (-습니다/-ㅂ니다)
- 발화 텍스트만 출력, 번호·레이블·설명 없이
"""


@dataclass
class Briefing:
    spoken_text: str
    hud_summary: str
    category: str
    confidence: float


async def brief_assistant_response(
    text: str,
    model: str = DEFAULT_MODEL,
    timeout_ms: int = 2500,
) -> Briefing:
    """Claude 응답 텍스트를 음성 브리핑으로 변환한다.

    코드 비중이 높은 경우 summarize_with_code_hint()를 사용하고,
    LLM 실패/타임아웃 시 extract_summary()로 폴백한다.
    """
    if not text.strip():
        return Briefing(spoken_text="", hud_summary="", category="empty", confidence=0.0)

    # 코드 비중 높은 응답은 LLM 없이 처리
    if has_heavy_code(text):
        spoken = summarize_with_code_hint(text)
        spoken = sanitize_for_speech(spoken)
        hud = spoken[:60] if spoken else ""
        return Briefing(
            spoken_text=spoken,
            hud_summary=hud,
            category="code_heavy",
            confidence=1.0,
        )

    # LLM 브리핑 생성 (타임아웃 적용)
    timeout_sec = timeout_ms / 1000.0
    try:
        raw = await asyncio.wait_for(
            chat_completion(
                messages=[
                    {"role": "system", "content": _BRIEFING_SYSTEM},
                    {"role": "user", "content": strip_markdown(text)[:3000]},
                ],
                model=model,
                max_completion_tokens=200,
                temperature=0.3,
            ),
            timeout=timeout_sec,
        )
        if raw and raw.strip():
            spoken = sanitize_for_speech(raw.strip())
            hud = spoken[:60] if spoken else ""
            return Briefing(
                spoken_text=spoken,
                hud_summary=hud,
                category="briefing",
                confidence=0.9,
            )
    except asyncio.TimeoutError:
        _log.warning("brief_assistant_response: LLM timeout (%.1fs) — extract_summary로 폴백", timeout_sec)
    except Exception as exc:
        _log.warning("brief_assistant_response: LLM 오류 (%s) — extract_summary로 폴백", type(exc).__name__)

    # 폴백: 기존 extract_summary 경로
    try:
        spoken = await extract_summary(text, model=model)
    except Exception:
        clean = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        spoken = sanitize_for_speech(strip_markdown(clean)[:200])

    hud = spoken[:60] if spoken else ""
    return Briefing(
        spoken_text=spoken,
        hud_summary=hud,
        category="fallback",
        confidence=0.5,
    )


# ── 명령 실패 설명 ──────────────────────────────────────────────────────────────

# 시크릿 redact: 30자 이상 영숫자+특수문자 연속 패턴
_SECRET_RE = re.compile(r'[A-Za-z0-9!@#$%^&*()\-_=+\[\]{};:\'",.<>?/\\|`~]{30,}')

_FAILURE_SYSTEM = """\
당신은 빌드/테스트 실패를 간결하게 설명하는 어시스턴트입니다.
아래 실패한 명령과 출력을 보고 한국어 1-2문장 경어체로 설명하세요.

포함할 내용:
- 실패한 명령 타입 (빌드/테스트/패키지설치 등)
- 핵심 에러 라인 요약
- 가능성 높은 원인
- 다음으로 확인할 단계

출력 규칙:
- 마크다운 금지 (**, *, #, ` 등)
- 경어체 사용 (-습니다/-ㅂ니다)
- 1-2문장만 출력
"""


def _redact_secrets(text: str) -> str:
    """30자 이상 연속 토큰 패턴을 [REDACTED]로 치환한다."""
    return _SECRET_RE.sub("[REDACTED]", text)


def _extract_relevant_lines(output: str, max_lines: int = 30) -> str:
    """출력에서 마지막 max_lines개 라인을 반환한다.

    error/fail/warning 포함 라인을 우선 포함하되,
    전체 라인 수가 max_lines를 초과하면 마지막 max_lines개만 사용한다.
    """
    lines = output.splitlines()
    if len(lines) <= max_lines:
        return "\n".join(lines)
    return "\n".join(lines[-max_lines:])


async def explain_command_failure(
    cmd: str,
    output: str,
    exit_code: int,
    model: str = DEFAULT_MODEL,
    timeout_ms: int = 2500,
) -> str:
    """빌드/테스트 명령 실패를 LLM으로 설명한다.

    성공(exit_code == 0)이면 LLM 호출 없이 빈 문자열을 반환한다.
    LLM 실패 또는 timeout 시 빈 문자열을 반환한다 (fail-open).
    """
    if exit_code == 0:
        return ""

    relevant = _extract_relevant_lines(output)
    safe_output = _redact_secrets(relevant)
    safe_cmd = _redact_secrets(cmd)

    user_content = f"명령: {safe_cmd}\nexit code: {exit_code}\n\n출력:\n{safe_output}"

    timeout_sec = timeout_ms / 1000.0
    try:
        raw = await asyncio.wait_for(
            chat_completion(
                messages=[
                    {"role": "system", "content": _FAILURE_SYSTEM},
                    {"role": "user", "content": user_content},
                ],
                model=model,
                max_completion_tokens=150,
                temperature=0.2,
            ),
            timeout=timeout_sec,
        )
        if raw and raw.strip():
            return sanitize_for_speech(raw.strip())
    except asyncio.TimeoutError:
        _log.warning("explain_command_failure: LLM timeout (%.1fs)", timeout_sec)
    except Exception as exc:
        _log.warning("explain_command_failure: LLM 오류 (%s)", type(exc).__name__)

    return ""
