# tests/test_summarizer.py
import pytest
from unittest.mock import patch, AsyncMock
from hook_voice.summarizer import strip_markdown, sanitize_for_speech, extract_summary, extract_one_liner

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

async def test_extract_summary_returns_empty_for_blank():
    result = await extract_summary("   ")
    assert result == ""
