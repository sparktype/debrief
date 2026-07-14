# hook_voice/event/canonical.py — 소스 공통 이벤트 스키마 (CanonicalEvent)
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    CRITICAL = "critical"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    INFO = "info"


class InterruptPolicy(str, Enum):
    ALWAYS = "always"    # 현재 발화 중단 후 즉시 재생
    QUEUE = "queue"      # 현재 발화 완료 후 재생
    DISCARD = "discard"  # 큐가 가득 찼을 때 버림


@dataclass(frozen=True)
class LanguageProfile:
    primary: str       # "ko" | "en" | "mixed"
    confidence: float  # 0.0–1.0
    script: str        # "hangul" | "latin" | "mixed"
    mixed_content: bool


@dataclass
class CanonicalEvent:
    """소스 독립적 이벤트 표현. 파이프라인 각 단계에서 필드가 보강된다."""

    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    idempotency_key: str = ""
    fingerprint: str = ""
    dedupe_key: str = ""
    correlation_id: str = ""

    # 소스 정보
    source: str = ""            # "coding_agent" | "grafana"
    source_event_type: str = "" # "stop" | "subagent_stop" | "alert_firing" | "alert_resolved"

    # 우선순위 및 처리 방침
    severity: Severity = Severity.INFO
    priority_score: int = 0     # 0–100 (높을수록 먼저 재생)
    interrupt_policy: InterruptPolicy = InterruptPolicy.QUEUE

    # 콘텐츠
    raw_text: str = ""
    language: LanguageProfile | None = None
    ttl: float = 30.0           # 초 — 만료되면 DLQ 이동

    # 추적
    version: int = 1
    trace_id: str = ""
    created_at: float = field(default_factory=time.time)
    metadata: dict = field(default_factory=dict)

    def is_expired(self) -> bool:
        return time.time() - self.created_at > self.ttl

    def __lt__(self, other: "CanonicalEvent") -> bool:
        # PriorityQueue 정렬: priority_score 높은 것 먼저, 동점이면 created_at 오래된 것 먼저
        if self.priority_score != other.priority_score:
            return self.priority_score > other.priority_score
        return self.created_at < other.created_at
