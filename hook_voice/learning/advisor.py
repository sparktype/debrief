# hook_voice/learning/advisor.py — 사용 통계 분석 → .voice.json 설정 권장안 생성
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Any


@dataclass
class Suggestion:
    """단일 설정 권장안."""
    key: str          # 권장 대상 키 (예: "ttsSpeed", "builder_priority")
    current: Any      # 현재 값 (알 수 없으면 None)
    recommended: Any  # 권장 값
    reason: str       # 사유 문장 (경어체)


_MIN_STATS = 10          # 제안 생성에 필요한 최소 통계 수
_INTERRUPT_THRESHOLD = 0.5   # 전체 중단율 임계값
_AGENT_COMPLETION_MIN = 0.6  # 에이전트별 완료율 최소값
_AGENT_MIN_SAMPLES = 5       # 에이전트별 최소 샘플 수


def analyze(stats: list[dict]) -> list[Suggestion]:
    """통계 목록을 분석해 설정 권장안 리스트를 반환한다.

    통계가 _MIN_STATS건 미만이면 빈 리스트를 반환한다.
    """
    if len(stats) < _MIN_STATS:
        return []

    suggestions: list[Suggestion] = []

    # 1. 전체 중단율 > 50% → ttsSpeed 낮추기 권장
    total = len(stats)
    interrupted = sum(1 for s in stats if not s.get("completed", True))
    interrupt_rate = interrupted / total
    if interrupt_rate > _INTERRUPT_THRESHOLD:
        suggestions.append(Suggestion(
            key="ttsSpeed",
            current=None,
            recommended=0.95,
            reason=(
                f"최근 {total}건 중 {interrupted}건({interrupt_rate:.0%})이 중단됐습니다. "
                "재생 속도를 낮추면 끝까지 듣는 비율이 높아질 수 있습니다."
            ),
        ))

    # 2. 에이전트별 완료율 < 60% → LOW 우선순위 권장
    agent_stats: dict[str, list[bool]] = defaultdict(list)
    for s in stats:
        atype = s.get("agent_type", "default")
        if atype == "default":
            continue
        agent_stats[atype].append(bool(s.get("completed", True)))

    for agent, completions in agent_stats.items():
        if len(completions) < _AGENT_MIN_SAMPLES:
            continue
        rate = sum(completions) / len(completions)
        if rate < _AGENT_COMPLETION_MIN:
            suggestions.append(Suggestion(
                key=f"{agent}_priority",
                current="NORMAL",
                recommended="LOW",
                reason=(
                    f"{agent} 에이전트 응답 {len(completions)}건 중 완료율이 "
                    f"{rate:.0%}입니다. voice-map.json에서 해당 에이전트의 "
                    "우선순위를 LOW로 설정하면 다른 응답을 방해하지 않습니다."
                ),
            ))

    return suggestions
