# hook_voice/voice_router.py
# 에이전트 타입을 카테고리·Supertonic voice ID로 변환하는 라우터
import json
from pathlib import Path
from typing import TypedDict

_DEFAULT_VOICE_MAP_PATH = Path(__file__).parent.parent / "voice-map.json"

_CATEGORY_LABELS: dict[str, str] = {
    "reviewer": "리뷰어",
    "planner": "플래너",
    "builder": "빌더",
    "tester": "테스터",
    "explorer": "탐색기",
}


class VoiceMap(TypedDict):
    supertonic: dict
    voices: dict[str, str]
    categories: dict[str, list[str]]


_FALLBACK_MAP: VoiceMap = {
    "supertonic": {"lang": "ko"},
    "voices": {"default": "F1"},
    "categories": {},
}


def load_voice_map(path: Path | None = None) -> VoiceMap:
    target = path or _DEFAULT_VOICE_MAP_PATH
    if not target.exists():
        return dict(_FALLBACK_MAP)  # type: ignore[return-value]
    try:
        parsed = json.loads(target.read_text(encoding="utf-8"))
        if not all(k in parsed for k in ("supertonic", "voices", "categories")):
            return dict(_FALLBACK_MAP)  # type: ignore[return-value]
        return parsed
    except Exception:
        return dict(_FALLBACK_MAP)  # type: ignore[return-value]


def resolve_voice(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    for cat, agents in m["categories"].items():
        if agent_type in agents:
            return m["voices"].get(cat) or m["voices"].get("default", "F1")
    return m["voices"].get("default", "F1")


def get_agent_label(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    for cat, agents in m["categories"].items():
        if agent_type in agents:
            return _CATEGORY_LABELS.get(cat, "에이전트")
    return "에이전트"
