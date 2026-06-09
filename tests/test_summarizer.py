# tests/test_summarizer.py
import pytest
from unittest.mock import patch, AsyncMock
from hook_voice.summarizer import strip_markdown, sanitize_for_speech, extract_summary, extract_one_liner, extract_one_liner_with_tag, select_expression_tag, retouch_for_speech

def test_strip_markdown_removes_code_blocks():
    result = strip_markdown("앞\n```python\ncode\n```\n뒤")
    assert "[코드 생략]" in result
    assert "앞" in result

def test_strip_markdown_removes_headers():
    assert strip_markdown("# 제목") == "제목"

def test_sanitize_for_speech_removes_special_chars():
    result = sanitize_for_speech("안녕 *world* 🎉")
    assert "🎉" not in result
    assert "안녕" in result


def test_sanitize_for_speech_preserves_expression_tags():
    """Supertonic Expression Tags는 sanitize 후에도 보존되어야 한다."""
    result = sanitize_for_speech("<breath> 안녕하세요 <laugh>")
    assert "<breath>" in result
    assert "<laugh>" in result
    assert "안녕하세요" in result


def test_sanitize_for_speech_preserves_all_known_tags():
    tags = ["<breath>", "<laugh>", "<sigh>", "<clear_throat>", "<hmm>",
            "<cough>", "<sniff>", "<gasp>", "<yawn>", "<cry>"]
    for tag in tags:
        result = sanitize_for_speech(f"{tag} 텍스트")
        assert tag in result, f"{tag}가 sanitize 후 사라짐"


def test_sanitize_for_speech_removes_unknown_angle_brackets():
    """알 수 없는 꺾쇠 태그는 제거된다."""
    result = sanitize_for_speech("<unknown> 텍스트 <br>")
    assert "<unknown>" not in result
    assert "<br>" not in result
    assert "텍스트" in result

async def test_extract_summary_uses_llm():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="LLM 요약")) as mock:
        result = await extract_summary("긴 텍스트입니다.")
        assert result == "LLM 요약"
        mock.assert_called_once()

async def test_extract_summary_falls_back_on_empty_llm():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="")):
        result = await extract_summary("첫 문장. 두 번째 문장. 세 번째 문장.")
        assert len(result) > 0

async def test_extract_one_liner_sanitizes_result():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="결과 *완료*")):
        result = await extract_one_liner("작업 텍스트")
        assert "*" not in result


async def test_extract_one_liner_with_tag_returns_tuple():
    """LLM JSON 응답을 (one_liner, tag) 튜플로 반환한다."""
    import json
    llm_response = json.dumps({"one_liner": "테스트 통과됐습니다", "tag": "laugh"})
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value=llm_response)):
        one_liner, tag = await extract_one_liner_with_tag("텍스트", "tester")
    assert one_liner == "테스트 통과됐습니다"
    assert tag == "<laugh>"


async def test_extract_one_liner_with_tag_invalid_tag_falls_back_to_breath():
    """LLM이 유효하지 않은 태그를 반환하면 <breath>로 폴백한다."""
    import json
    llm_response = json.dumps({"one_liner": "작업 완료", "tag": "unknown_tag"})
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value=llm_response)):
        one_liner, tag = await extract_one_liner_with_tag("텍스트", "builder")
    assert tag == "<breath>"


async def test_extract_one_liner_with_tag_llm_failure_uses_rule_fallback():
    """LLM 실패 시 규칙 기반 폴백(select_expression_tag)을 사용한다."""
    with patch("hook_voice.summarizer.chat_completion", side_effect=Exception("LLM 오류")):
        one_liner, tag = await extract_one_liner_with_tag("치명적 시스템 장애 발생", "ops")
    assert tag == "<cry>"


async def test_extract_one_liner_with_tag_empty_input():
    """빈 텍스트는 빈 문자열과 role default 태그를 반환한다."""
    one_liner, tag = await extract_one_liner_with_tag("", "reviewer")
    assert one_liner == ""
    assert tag == "<breath>"

async def test_extract_summary_returns_empty_for_blank():
    result = await extract_summary("   ")
    assert result == ""


# ── select_expression_tag 테스트 ──────────────────────────────

def test_select_tag_critical_keywords():
    """치명·장애·다운 키워드 → cry (최우선)."""
    assert select_expression_tag("서비스 장애 발생", "ops") == "<cry>"
    assert select_expression_tag("치명적 오류", "builder") == "<cry>"
    assert select_expression_tag("시스템 다운", "guardian") == "<cry>"


def test_select_tag_surprise_keywords():
    """예상치못·의외·갑자기 키워드 → gasp."""
    assert select_expression_tag("예상치 못한 결과", "explorer") == "<gasp>"
    assert select_expression_tag("갑자기 동작이 바뀜", "reviewer") == "<gasp>"
    assert select_expression_tag("의외의 패턴 발견", "planner") == "<gasp>"


def test_select_tag_caution_keywords():
    """위험·삭제 키워드 → clear_throat."""
    assert select_expression_tag("파일 삭제 완료", "builder") == "<clear_throat>"
    assert select_expression_tag("주의가 필요합니다", "reviewer") == "<clear_throat>"
    assert select_expression_tag("되돌릴 수 없는 작업", "default") == "<clear_throat>"


def test_select_tag_regret_keywords():
    """아쉽·미완성·부족 키워드 → sniff."""
    assert select_expression_tag("아쉽게도 미완성", "builder") == "<sniff>"
    assert select_expression_tag("기능이 부족합니다", "reviewer") == "<sniff>"


def test_select_tag_negative_keywords():
    """실패·에러 키워드 → sigh."""
    assert select_expression_tag("빌드 실패", "builder") == "<sigh>"
    assert select_expression_tag("타입 에러 발생", "reviewer") == "<sigh>"
    assert select_expression_tag("오류가 있습니다", "tester") == "<sigh>"


def test_select_tag_tester_success():
    """tester + 성공 키워드 → laugh."""
    assert select_expression_tag("전체 테스트 통과", "tester") == "<laugh>"
    assert select_expression_tag("완벽하게 성공", "tester") == "<laugh>"


def test_select_tag_discovery_for_explorer():
    """탐색·발견 키워드 + explorer → hmm."""
    assert select_expression_tag("흥미로운 패턴 발견", "explorer") == "<hmm>"
    assert select_expression_tag("코드 분석 결과", "reviewer") == "<hmm>"


def test_select_tag_ops_routine():
    """ops + 정상·이상없음 → yawn."""
    assert select_expression_tag("시스템 정상", "ops") == "<yawn>"
    assert select_expression_tag("이상없음 확인", "ops") == "<yawn>"


def test_select_tag_role_defaults():
    """콘텐츠 중립 → 역할 기본 태그 (voice 특성 기반으로 재조정됨)."""
    assert select_expression_tag("작업 완료했습니다", "reviewer") == "<breath>"
    assert select_expression_tag("계획을 수립했습니다", "planner") == "<hmm>"
    assert select_expression_tag("중립 메시지", "explorer") == "<hmm>"
    assert select_expression_tag("중립 메시지", "guardian") == "<breath>"
    assert select_expression_tag("보고합니다", "ops") == "<clear_throat>"


def test_select_tag_builder_optimizer_default_tag():
    """builder / optimizer 중립 콘텐츠 기본 태그 (voice 특성 기반으로 재조정됨)."""
    assert select_expression_tag("구현 완료", "builder") == "<breath>"
    assert select_expression_tag("최적화 완료", "optimizer") == "<hmm>"


def test_select_tag_priority_critical_beats_all():
    """critical이 다른 모든 키워드보다 우선."""
    assert select_expression_tag("장애 발생으로 삭제", "ops") == "<cry>"


def test_select_tag_caution_beats_negative():
    """경고 키워드가 실패 키워드보다 우선순위 높음."""
    assert select_expression_tag("삭제 실패", "builder") == "<clear_throat>"


async def test_extract_summary_sanitizes_markdown_in_llm_result():
    """LLM이 마크다운을 반환해도 sanitize 후 반환된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="결과는 **중요함**")):
        result = await extract_summary("텍스트")
        assert "**" not in result
        assert "중요함" in result


async def test_extract_summary_sanitizes_fallback():
    """LLM 결과가 없을 때 fallback도 sanitize된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="")):
        result = await extract_summary("첫 문장. 두 번째!? 마지막.")
        assert result  # 비어 있지 않음


async def test_retouch_removes_markdown():
    """LLM이 마크다운 제거 결과를 반환하면 그대로 전달."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="굵은글씨")):
        result = await retouch_for_speech("**굵은글씨**")
        assert result == "굵은글씨"


async def test_retouch_converts_it_terms():
    """LLM이 IT 용어를 한국어 발음으로 변환한 결과를 반환."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="에이피아이 호출 완료")):
        result = await retouch_for_speech("API 호출 완료")
        assert "에이피아이" in result


async def test_retouch_preserves_expression_tags():
    """Expression Tag는 sanitize 후에도 보존된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="<breath> 안녕하세요")):
        result = await retouch_for_speech("<breath> 안녕하세요")
        assert "<breath>" in result
        assert "안녕하세요" in result


async def test_retouch_fallback_on_llm_failure():
    """LLM 예외 시 sanitize_for_speech 결과를 반환한다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(side_effect=Exception("network error"))):
        result = await retouch_for_speech("**굵은글씨** 텍스트")
        assert "**" not in result
        assert "텍스트" in result


async def test_retouch_returns_blank_for_blank_input():
    """빈 문자열 입력은 LLM 호출 없이 그대로 반환."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock()) as mock_llm:
        result = await retouch_for_speech("   ")
        mock_llm.assert_not_called()
        assert result.strip() == ""
