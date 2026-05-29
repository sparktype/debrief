# hook_voice/adapters/base.py — Source Adapter 추상 인터페이스
from __future__ import annotations

from typing import Protocol, runtime_checkable

from ..event.canonical import CanonicalEvent


@runtime_checkable
class SourceAdapterProtocol(Protocol):
    """모든 소스 어댑터가 구현해야 하는 프로토콜."""

    def source_id(self) -> str:
        """이 어댑터가 담당하는 소스 식별자 ('coding_agent', 'grafana' 등)."""
        ...

    async def to_canonical_event(self, raw: str, **kwargs) -> CanonicalEvent | None:
        """원시 입력을 CanonicalEvent로 변환. 변환 불가 시 None 반환."""
        ...

    async def health_check(self) -> bool:
        """소스 연결 상태 확인. True = 정상."""
        ...
