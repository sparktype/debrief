# hook_voice/speech/pipeline.py — Speech Preparation Plugin Chain 조율자
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class SpeechContext:
    """파이프라인 각 단계가 읽고 쓰는 공유 상태."""
    text: str
    language: str = "ko"                  # "ko" | "en" | "mixed"
    language_confidence: float = 1.0
    segments: list[str] = field(default_factory=list)
    ssml: str = ""
    metadata: dict = field(default_factory=dict)


Stage = Callable[[SpeechContext], SpeechContext]


class SpeechPipeline:
    """등록 순서대로 Stage를 실행하는 선형 파이프라인 (Phase 1).

    async Stage는 await로, 동기 Stage는 직접 호출한다.
    """

    def __init__(self, stages: list[Stage] | None = None) -> None:
        self._stages: list[Stage] = stages or []

    def add_stage(self, stage: Stage) -> None:
        self._stages.append(stage)

    async def process(self, text: str, language_hint: str = "ko") -> SpeechContext:
        ctx = SpeechContext(text=text, language=language_hint)
        for stage in self._stages:
            if asyncio.iscoroutinefunction(stage):
                ctx = await stage(ctx)
            else:
                ctx = stage(ctx)
        return ctx


def build_default_pipeline() -> SpeechPipeline:
    """기본 8단계 파이프라인을 조립해 반환한다."""
    from .stages.lang_detect import lang_detect_stage
    from .stages.segment_splitter import segment_splitter_stage
    from .stages.identifier_normalizer import identifier_normalizer_stage
    from .stages.pattern_suppressor import pattern_suppressor_stage
    from .stages.pronunciation_dict import pronunciation_dict_stage
    from .stages.normalization import normalization_stage
    from .stages.prosody_boundary import prosody_boundary_stage
    from .stages.ssml_abstraction import ssml_abstraction_stage

    return SpeechPipeline([
        lang_detect_stage,
        segment_splitter_stage,
        identifier_normalizer_stage,
        pattern_suppressor_stage,
        pronunciation_dict_stage,
        normalization_stage,
        prosody_boundary_stage,
        ssml_abstraction_stage,
    ])


# 모듈 싱글톤 — 전역 재사용
_default_pipeline: SpeechPipeline | None = None


def get_default_pipeline() -> SpeechPipeline:
    global _default_pipeline
    if _default_pipeline is None:
        _default_pipeline = build_default_pipeline()
    return _default_pipeline
