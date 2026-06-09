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
    "optimizer": "옵티마이저",
    "guardian": "가디언",
    "ops": "옵스",
    "specialist": "스페셜리스트",
}


class VoiceMap(TypedDict):
    supertonic: dict
    voice_settings: dict[str, dict]
    voices: dict[str, str]
    voice_names: dict[str, str]
    instructs: dict[str, str]
    categories: dict[str, list[str]]


_FALLBACK_MAP: VoiceMap = {
    "supertonic": {"lang": "ko"},
    "voices": {"default": "F1"},
    "voice_names": {"F1": "연아"},
    "instructs": {"default": "밝고 친절하게 말해주세요"},
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


def _resolve_category(agent_type: str, m: VoiceMap) -> str | None:
    for cat, agents in m["categories"].items():
        if agent_type in agents:
            return cat
    return None


def resolve_voice(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    cat = _resolve_category(agent_type, m)
    if cat:
        return m["voices"].get(cat) or m["voices"].get("default", "F1")
    return m["voices"].get("default", "F1")


def resolve_voice_name(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    voice_id = resolve_voice(agent_type, m)
    return m.get("voice_names", {}).get(voice_id, voice_id)


def resolve_instruct(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    cat = _resolve_category(agent_type, m)
    instructs = m.get("instructs", {})
    if cat and cat in instructs:
        return instructs[cat]
    return instructs.get("default", "밝고 친절하게 말해주세요")


def resolve_category(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    """agent_type → 카테고리명 (reviewer/builder/... 또는 'default')"""
    m = voice_map or load_voice_map()
    return _resolve_category(agent_type, m) or "default"


def get_agent_label(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    cat = _resolve_category(agent_type, m)
    if cat:
        return _CATEGORY_LABELS.get(cat, "에이전트")
    return "에이전트"


def resolve_voice_settings(agent_type: str, voice_map: VoiceMap | None = None) -> dict:
    """voice ID 기반으로 synth_speed, steps 설정을 반환한다."""
    m = voice_map or load_voice_map()
    voice_id = resolve_voice(agent_type, m)
    defaults = {"synth_speed": 1.05, "steps": m.get("supertonic", {}).get("steps", 8)}
    settings = m.get("voice_settings", {})
    return {**defaults, **settings.get(voice_id, {})}
