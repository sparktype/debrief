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
