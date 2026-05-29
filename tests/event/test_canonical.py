# tests/event/test_canonical.py — CanonicalEvent 단위 테스트
import time
import pytest

from hook_voice.event.canonical import (
    CanonicalEvent,
    LanguageProfile,
    Severity,
    InterruptPolicy,
)


def test_default_fields():
    ev = CanonicalEvent()
    assert ev.event_id != ""
    assert ev.source == ""
    assert ev.severity == Severity.INFO
    assert ev.interrupt_policy == InterruptPolicy.QUEUE
    assert ev.priority_score == 0
    assert not ev.is_expired()


def test_custom_severity():
    ev = CanonicalEvent(severity=Severity.CRITICAL, priority_score=90)
    assert ev.severity == Severity.CRITICAL
    assert ev.priority_score == 90


def test_language_profile():
    lp = LanguageProfile(primary="ko", confidence=0.9, script="hangul", mixed_content=False)
    ev = CanonicalEvent(language=lp)
    assert ev.language.primary == "ko"
    assert ev.language.confidence == 0.9


def test_is_expired():
    ev = CanonicalEvent(ttl=0.01)
    ev.created_at = time.time() - 1.0  # 1초 전 생성
    assert ev.is_expired()


def test_not_expired_default():
    ev = CanonicalEvent(ttl=30.0)
    assert not ev.is_expired()


def test_ordering_by_priority():
    low = CanonicalEvent(priority_score=10)
    high = CanonicalEvent(priority_score=90)
    assert high < low  # priority_score 높은 것이 "더 작다" (PriorityQueue에서 먼저 꺼남)


def test_ordering_by_created_at():
    older = CanonicalEvent(priority_score=50)
    newer = CanonicalEvent(priority_score=50)
    older.created_at = time.time() - 1.0
    newer.created_at = time.time()
    assert older < newer  # 동점이면 오래된 것 먼저


def test_interrupt_policy_enum():
    assert InterruptPolicy.ALWAYS == "always"
    assert InterruptPolicy.QUEUE == "queue"
    assert InterruptPolicy.DISCARD == "discard"


def test_severity_enum():
    assert Severity.CRITICAL == "critical"
    assert Severity.INFO == "info"
