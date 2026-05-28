# tests/test_skill_recommender.py
import json
import pytest
from pathlib import Path
from unittest.mock import patch, AsyncMock
from hook_voice.skill_recommender import (
    parse_catalog, parse_recommendation, is_in_cooldown,
    load_cooldowns, save_cooldown, recommend_skill,
    read_recent_transcripts,
)

_CATALOG = [
    {"skill": "superpowers:brainstorming", "description": "아이디어를 설계로"},
    {"skill": "superpowers:writing-plans", "description": "구현 계획 작성"},
]

def test_parse_catalog_valid():
    raw = json.dumps(_CATALOG)
    result = parse_catalog(raw)
    assert len(result) == 2
    assert result[0]["skill"] == "superpowers:brainstorming"

def test_parse_catalog_invalid_returns_empty():
    assert parse_catalog("not json") == []
    assert parse_catalog('"string"') == []

def test_parse_recommendation_valid():
    raw = json.dumps({"skill": "superpowers:brainstorming", "reason": "아이디어 정리 중"})
    rec = parse_recommendation(raw, _CATALOG)
    assert rec is not None
    assert rec["skill"] == "superpowers:brainstorming"

def test_parse_recommendation_unknown_skill():
    raw = json.dumps({"skill": "unknown:skill", "reason": "이유"})
    assert parse_recommendation(raw, _CATALOG) is None

def test_is_in_cooldown_true():
    from datetime import datetime, timezone, timedelta
    recent = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    assert is_in_cooldown("some-skill", {"some-skill": recent}, cooldown_minutes=30) is True

def test_is_in_cooldown_false_expired():
    from datetime import datetime, timezone, timedelta
    old = (datetime.now(timezone.utc) - timedelta(minutes=60)).isoformat()
    assert is_in_cooldown("some-skill", {"some-skill": old}, cooldown_minutes=30) is False

def test_is_in_cooldown_false_no_entry():
    assert is_in_cooldown("some-skill", {}, cooldown_minutes=30) is False

def test_save_and_load_cooldown(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_cooldown("superpowers:brainstorming")
    cooldowns = load_cooldowns()
    assert "superpowers:brainstorming" in cooldowns

async def test_recommend_skill_returns_recommendation(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    catalog_json = json.dumps(_CATALOG)
    with patch("hook_voice.skill_recommender._CATALOG_FILE") as mock_file:
        mock_file.read_text.return_value = catalog_json
        with patch(
            "hook_voice.skill_recommender.chat_completion",
            new=AsyncMock(return_value=json.dumps({"skill": "superpowers:brainstorming", "reason": "이유"})),
        ):
            rec = await recommend_skill("대화 컨텍스트", bypass_cooldown=True)
            assert rec is not None
            assert rec["skill"] == "superpowers:brainstorming"

def test_read_recent_transcripts_empty_dir(tmp_path):
    result = read_recent_transcripts(transcripts_dir=tmp_path)
    assert result == ""

def test_read_recent_transcripts_nonexistent_dir(tmp_path):
    result = read_recent_transcripts(transcripts_dir=tmp_path / "no-such-dir")
    assert result == ""


def test_read_recent_transcripts_supports_message_role_schema(tmp_path):
    transcript = tmp_path / "session.jsonl"
    transcript.write_text(
        "\n".join([
            json.dumps({"message": {"role": "user", "content": [{"type": "text", "text": "사용자 질문"}]}}),
            json.dumps({"message": {"role": "assistant", "content": [{"type": "text", "text": "어시스턴트 답변"}]}}),
        ]),
        encoding="utf-8",
    )

    result = read_recent_transcripts(transcripts_dir=tmp_path)
    assert "User: 사용자 질문" in result
    assert "Assistant: 어시스턴트 답변" in result
