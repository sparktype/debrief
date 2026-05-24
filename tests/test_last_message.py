# tests/test_last_message.py
import pytest
from pathlib import Path
from hook_voice.last_message import save_last_message, load_last_message

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
