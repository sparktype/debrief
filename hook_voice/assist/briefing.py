# hook_voice/assist/briefing.py — LLM 응답 브리핑 및 명령 실패 설명 생성 모듈
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path

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
    except asyncio.CancelledError:
        raise
    except asyncio.TimeoutError:
        _log.warning("brief_assistant_response: LLM timeout (%.1fs) — extract_summary로 폴백", timeout_sec)
    except Exception as exc:
        _log.warning("brief_assistant_response: LLM 오류 (%s) — extract_summary로 폴백", type(exc).__name__)

    # 폴백: 기존 extract_summary 경로
    try:
        spoken = await extract_summary(text, model=model)
    except asyncio.CancelledError:
        raise
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


# ── 명령 위험 설명 ──────────────────────────────────────────────────────────────

# 쿨다운 파일 기반 영속화: 각 hook이 새 subprocess이므로 in-memory dict는 무의미
_RISK_COOLDOWN_PATH = Path("~/.local/share/chorus/risk-cooldowns.json").expanduser()
_RISK_COOLDOWN_SEC = 60.0


def _load_risk_cooldowns() -> dict[str, float]:
    """파일에서 쿨다운 타임스탬프를 읽어온다. 파일 없으면 {}."""
    try:
        if _RISK_COOLDOWN_PATH.exists():
            return json.loads(_RISK_COOLDOWN_PATH.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {}


def _save_risk_cooldowns(cooldowns: dict[str, float]) -> None:
    """쿨다운 타임스탬프를 파일에 atomic write로 저장한다."""
    try:
        _RISK_COOLDOWN_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = _RISK_COOLDOWN_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(cooldowns), encoding="utf-8")
        tmp.replace(_RISK_COOLDOWN_PATH)
    except Exception:
        pass


def _is_risk_in_cooldown(family: str) -> bool:
    """파일 기반 쿨다운을 확인한다. 60초 이내면 True."""
    cooldowns = _load_risk_cooldowns()
    last = cooldowns.get(family, 0.0)
    return (time.time() - last) < _RISK_COOLDOWN_SEC


def _set_risk_cooldown(family: str) -> None:
    """파일에 현재 시각을 쿨다운으로 저장한다."""
    cooldowns = _load_risk_cooldowns()
    cooldowns[family] = time.time()
    _save_risk_cooldowns(cooldowns)

_RISK_SYSTEM = """\
당신은 개발자에게 위험한 터미널 명령 실행 전 간결하게 주의를 알리는 어시스턴트입니다.
아래 명령의 위험성을 한국어 1문장 경어체로 설명하세요.

출력 규칙:
- 마크다운 금지 (**, *, #, ` 등)
- 경어체 사용 (-습니다/-ㅂ니다)
- 정확히 1문장만 출력
"""

# 고위험 패턴: 해당 패턴 매칭 시 LLM 호출
_HIGH_RISK_PATTERNS = re.compile(
    r"rm\s+-[^\s]*rf|rm\s+-rf"  # rm -rf (순서 무관)
    r"|git\s+reset\s+--hard"
    r"|git\s+clean\s+-[^\s]*f"  # git clean -f, -df 등
    r"|pip\s+install|pip3\s+install"
    r"|npm\s+install|npm\s+ci|yarn\s+add|pnpm\s+add"
    r"|curl\s+[^|]+\|\s*(sh|bash)"  # curl ... | sh/bash
    r"|\|\s*(sh|bash)\s*$"  # pipe to sh/bash at end
    r"|\bsudo\b"
    r"|/etc/|/usr/|/prod/",
    re.IGNORECASE,
)


def _classify_risk(cmd: str) -> str:
    """커맨드 위험 수준을 분류한다.

    Returns:
        "high" — 고위험 (LLM 설명 필요)
        "low"  — 저위험 (LLM 불필요)
    """
    if _HIGH_RISK_PATTERNS.search(cmd):
        return "high"
    return "low"


async def explain_command_risk(
    cmd: str,
    model: str = DEFAULT_MODEL,
    timeout_ms: int = 2500,
) -> str:
    """PreToolUse Bash 실행 전 고위험 커맨드를 LLM으로 설명한다.

    저위험 커맨드는 즉시 "" 반환 (LLM 없음).
    동일 커맨드 패밀리(첫 단어) 60초 쿨다운 내 재호출도 "" 반환.
    쿨다운은 파일 기반으로 subprocess 재시작 후에도 유지된다.
    LLM 실패/timeout 시 "" 반환 (fail-open).
    최대 1문장 한국어 경어체 출력.
    """
    risk = _classify_risk(cmd)
    if risk == "low":
        return ""

    # 쿨다운 확인: 커맨드 첫 단어 기준 (파일 기반)
    family = cmd.strip().split()[0] if cmd.strip() else ""
    if _is_risk_in_cooldown(family):
        return ""

    # 고위험 → LLM 호출
    safe_cmd = _redact_secrets(cmd)
    timeout_sec = timeout_ms / 1000.0
    try:
        raw = await asyncio.wait_for(
            chat_completion(
                messages=[
                    {"role": "system", "content": _RISK_SYSTEM},
                    {"role": "user", "content": f"명령: {safe_cmd}"},
                ],
                model=model,
                max_completion_tokens=80,
                temperature=0.2,
            ),
            timeout=timeout_sec,
        )
        if raw and raw.strip():
            _set_risk_cooldown(family)
            return sanitize_for_speech(raw.strip())
    except asyncio.TimeoutError:
        _log.warning("explain_command_risk: LLM timeout (%.1fs)", timeout_sec)
    except Exception as exc:
        _log.warning("explain_command_risk: LLM 오류 (%s)", type(exc).__name__)

    return ""
