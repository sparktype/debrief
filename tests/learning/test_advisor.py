# 어드바이저 단위 테스트
import pytest


def _make_stat(agent_type="default", mode="full", priority="NORMAL",
               completed=True, duration_secs=3.0):
    return {
        "agent_type": agent_type,
        "mode": mode,
        "priority": priority,
        "completed": completed,
        "duration_secs": duration_secs,
    }


def test_analyze_returns_empty_when_too_few_stats():
    """통계가 10건 미만이면 제안이 없다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat() for _ in range(5)]
    result = analyze(stats)
    assert result == []


def test_analyze_suggests_low_priority_for_high_interrupt_agent():
    """특정 에이전트의 완료율이 60% 미만이면 LOW 우선순위를 권장한다."""
    from hook_voice.learning.advisor import analyze, Suggestion
    # builder: 10건 중 3건만 완료 (30% 완료율)
    stats = [_make_stat("builder", completed=True) for _ in range(3)]
    stats += [_make_stat("builder", completed=False) for _ in range(7)]
    stats += [_make_stat("default", completed=True) for _ in range(10)]  # 최소 10건 총계

    result = analyze(stats)
    keys = [s.key for s in result]
    assert any("builder" in k for k in keys)
    builder_sug = next(s for s in result if "builder" in s.key)
    assert builder_sug.recommended == "LOW"


def test_analyze_suggests_speed_reduction_when_high_interrupt_rate():
    """전체 중단율 > 50%이면 ttsSpeed 낮추기를 권장한다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=False) for _ in range(7)]
    stats += [_make_stat(completed=True) for _ in range(3)]
    # 총 10건, 중단율 70%

    result = analyze(stats)
    keys = [s.key for s in result]
    assert "ttsSpeed" in keys


def test_analyze_no_suggestion_when_completion_rate_ok():
    """완료율이 60% 이상이면 ttsSpeed 제안이 없다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=True) for _ in range(8)]
    stats += [_make_stat(completed=False) for _ in range(2)]
    # 총 10건, 완료율 80%

    result = analyze(stats)
    keys = [s.key for s in result]
    assert "ttsSpeed" not in keys


def test_suggestion_has_reason():
    """모든 제안에 reason 문자열이 있다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=False) for _ in range(7)]
    stats += [_make_stat(completed=True) for _ in range(3)]

    result = analyze(stats)
    for sug in result:
        assert isinstance(sug.reason, str)
        assert len(sug.reason) > 0


def test_analyze_informs_about_high_error_rate():
    """에러 발화 비중이 30%를 넘으면 info Suggestion이 생성된다."""
    from hook_voice.learning.advisor import analyze
    # HIGH priority 4건, NORMAL 6건 → 40% HIGH
    stats = [_make_stat(priority="HIGH") for _ in range(4)]
    stats += [_make_stat(priority="NORMAL") for _ in range(6)]
    result = analyze(stats)
    keys = [s.key for s in result]
    assert "error_priority_info" in keys


def test_analyze_passes_current_speed():
    """current_speed가 Suggestion.current에 반영된다."""
    from hook_voice.learning.advisor import analyze
    stats = [_make_stat(completed=False) for _ in range(7)]
    stats += [_make_stat(completed=True) for _ in range(3)]
    result = analyze(stats, current_speed=1.2)
    tts_sug = next((s for s in result if s.key == "ttsSpeed"), None)
    assert tts_sug is not None
    assert tts_sug.current == 1.2
