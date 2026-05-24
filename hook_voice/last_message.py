# hook_voice/last_message.py
# 마지막 TTS 재생 텍스트 저장 및 읽기
import os
from pathlib import Path


def _get_data_dir() -> Path:
    env = os.environ.get("VOICE_PERSONA_DATA_DIR")
    return Path(env) if env else Path.home() / ".local" / "share" / "voice-persona"


def _get_last_msg_file() -> Path:
    return _get_data_dir() / "last-message.txt"


def save_last_message(text: str) -> None:
    try:
        f = _get_last_msg_file()
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text, encoding="utf-8")
    except Exception:
        pass


def load_last_message() -> str | None:
    try:
        f = _get_last_msg_file()
        return f.read_text(encoding="utf-8") if f.exists() else None
    except Exception:
        return None
