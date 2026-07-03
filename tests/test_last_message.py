# tests/test_last_message.py
import json
import pytest
from pathlib import Path
from hook_voice.last_message import save_last_message, load_last_message, append_history, _rotate_history, _get_history_file, read_recent_summaries

def test_save_and_load(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_last_message("안녕하세요")
    assert load_last_message() == "안녕하세요"

def test_load_returns_none_when_no_file(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    assert load_last_message() is None

def test_save_overwrites_previous(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_last_message("첫 번째")
    save_last_message("두 번째")
    assert load_last_message() == "두 번째"


def test_append_history_creates_jsonl(tmp_path, monkeypatch):
    """append_history가 history.jsonl에 타임스탬프+텍스트를 기록한다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    append_history("테스트 발화입니다")
    hist = tmp_path / "history.jsonl"
    assert hist.exists()
    entry = json.loads(hist.read_text().strip())
    assert entry["text"] == "테스트 발화입니다"
    assert "ts" in entry


def test_rotate_history_trims_to_900(tmp_path):
    """1000줄 초과 시 처음 100줄을 제거해 901줄 유지한다 (1001 - 100 = 901)."""
    hist = tmp_path / "history.jsonl"
    lines = [json.dumps({"ts": f"2026-01-01", "text": f"line{i}"}) for i in range(1001)]
    hist.write_text("\n".join(lines) + "\n")
    _rotate_history(hist)
    result = hist.read_text().splitlines()
    assert len(result) == 901
    assert "line100" in result[0]  # first 100 lines removed


def test_read_recent_summaries_no_file(tmp_path, monkeypatch):
    """히스토리 파일 없으면 빈 리스트를 반환한다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    result = read_recent_summaries(10)
    assert result == []


def test_read_recent_summaries_returns_n(tmp_path, monkeypatch):
    """최근 N개 텍스트를 반환한다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    for i in range(5):
        append_history(f"메시지 {i}")
    result = read_recent_summaries(3)
    assert len(result) == 3
    assert result[-1] == "메시지 4"


def test_read_recent_summaries_with_code_blocks(tmp_path, monkeypatch):
    """코드 블록이 포함된 항목도 정상 반환된다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    text_with_code = "분석 완료\n```python\nprint('hello')\n```"
    append_history(text_with_code)
    result = read_recent_summaries(5)
    assert len(result) == 1
    assert result[0] == text_with_code


def test_read_recent_summaries_empty_history(tmp_path, monkeypatch):
    """파일이 있어도 내용이 없으면 빈 리스트를 반환한다."""
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    hist = tmp_path / "history.jsonl"
    hist.write_text("")
    result = read_recent_summaries(10)
    assert result == []
