# hook_voice/config.py
# 사용자 설정 파일 로더 및 기본값 관리
import json
import logging
from dataclasses import dataclass
from pathlib import Path

_logger = logging.getLogger(__name__)

_DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / ".voice-persona.json"

_KEY_MAP = {
    "autoSpeak": "auto_speak",
    "minChars": "min_chars",
    "voice": "voice",
    "summaryModel": "summary_model",
    "ttsSpeed": "tts_speed",
    "ttsInstruct": "tts_instruct",
    "skillCooldownMinutes": "skill_cooldown_minutes",
    "supertonicPort": "supertonic_port",
    "edgeTimeoutMs": "edge_timeout_ms",
    "supertonicTimeoutMs": "supertonic_timeout_ms",
}


@dataclass
class Config:
    auto_speak: bool = True
    min_chars: int = 50
    voice: str = "Sohee"
    summary_model: str = "gpt-5.4"
    tts_speed: float = 1.2
    tts_instruct: str = "밝고 활기차게 말해주세요"
    skill_cooldown_minutes: int = 30
    supertonic_port: int = 7788
    edge_timeout_ms: int = 10000
    supertonic_timeout_ms: int = 20000


def load_config(path: Path | None = None) -> Config:
    target = path or _DEFAULT_CONFIG_PATH
    if not target.exists():
        return Config()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        kwargs = {py_k: data[json_k] for json_k, py_k in _KEY_MAP.items() if json_k in data}
        return Config(**kwargs)
    except json.JSONDecodeError as e:
        _logger.warning("voice-persona.json 파싱 실패, 기본값 사용: %s", e)
        return Config()
    except Exception as e:
        _logger.warning("voice-persona.json 로드 실패, 기본값 사용: %s", e)
        return Config()
