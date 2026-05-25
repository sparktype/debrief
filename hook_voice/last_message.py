# hook_voice/last_message.py
# 마지막 TTS 재생 텍스트 저장 및 읽기, 발화 히스토리 기록
import json
import os
from datetime import datetime, timezone
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
        append_history(text)
    except Exception:
        pass


_HISTORY_MAX_LINES = 1000
_HISTORY_TRIM_COUNT = 100


def _get_history_file() -> Path:
    return _get_data_dir() / "history.jsonl"


def _rotate_history(hist: Path) -> None:
    try:
        lines = hist.read_text(encoding="utf-8").splitlines()
        if len(lines) > _HISTORY_MAX_LINES:
            hist.write_text(
                "\n".join(lines[_HISTORY_TRIM_COUNT:]) + "\n",
                encoding="utf-8",
            )
    except Exception:
        pass


def append_history(text: str) -> None:
    try:
        d = _get_data_dir()
        d.mkdir(parents=True, exist_ok=True)
        hist = _get_history_file()
        entry = {"ts": datetime.now(timezone.utc).isoformat(), "text": text}
        with open(hist, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        _rotate_history(hist)
    except Exception:
        pass


def load_last_message() -> str | None:
    try:
        f = _get_last_msg_file()
        return f.read_text(encoding="utf-8") if f.exists() else None
    except Exception:
        return None
