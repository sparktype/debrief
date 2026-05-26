# hook_voice/skill_recommender.py
# 사용자 transcript 분석 → HMG LLM → 스킬 추천 + 쿨다운 관리
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict

from .llm_client import chat_completion, DEFAULT_MODEL

_CATALOG_FILE = Path(__file__).parent.parent / "skills-catalog.json"
_CACHE_TTL = 60.0
_transcript_cache: dict[str, tuple[str, float]] = {}


class SkillEntry(TypedDict):
    skill: str
    description: str


class Recommendation(TypedDict):
    skill: str
    reason: str


def _get_data_dir() -> Path:
    env = os.environ.get("VOICE_PERSONA_DATA_DIR")
    return Path(env) if env else Path.home() / ".local" / "share" / "voice-persona"


def _get_cooldowns_file() -> Path:
    return _get_data_dir() / "skill-cooldowns.json"


def parse_catalog(raw: str) -> list[SkillEntry]:
    try:
        arr = json.loads(raw)
        return arr if isinstance(arr, list) else []
    except Exception:
        return []


def parse_recommendation(raw: str, catalog: list[SkillEntry]) -> Recommendation | None:
    try:
        rec = json.loads(raw)
        if not rec.get("skill"):
            return None
        if not any(s["skill"] == rec["skill"] for s in catalog):
            return None
        return {"skill": rec["skill"], "reason": rec.get("reason", "")}
    except Exception:
        return None


def load_catalog() -> list[SkillEntry]:
    try:
        return parse_catalog(_CATALOG_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []


def _extract_content(raw: object) -> str:
    if isinstance(raw, str):
        return raw[:300]
    if isinstance(raw, list):
        return " ".join(
            b["text"] for b in raw
            if isinstance(b, dict) and isinstance(b.get("text"), str)
        )[:300]
    return ""


def read_recent_transcripts(
    transcripts_dir: Path | None = None,
    max_files: int = 3,
    max_lines_per_file: int = 50,
) -> str:
    scan_dir = transcripts_dir or (Path.home() / ".claude" / "projects")
    cache_key = str(scan_dir)
    if cache_key in _transcript_cache:
        data, ts = _transcript_cache[cache_key]
        if time.time() - ts < _CACHE_TTL:
            return data
    if not scan_dir.exists():
        return ""
    try:
        glob_fn = scan_dir.glob if transcripts_dir else scan_dir.rglob
        files = sorted(glob_fn("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:max_files]
        parts: list[str] = []
        for f in files:
            for line in f.read_text(encoding="utf-8").splitlines()[-max_lines_per_file:]:
                try:
                    entry = json.loads(line)
                    content = _extract_content(entry.get("content", ""))
                    if entry.get("type") == "user":
                        parts.append(f"User: {content}")
                    elif entry.get("type") == "assistant":
                        parts.append(f"Assistant: {content}")
                except Exception:
                    pass
            parts.append("---")
        result = "\n".join(parts)
        _transcript_cache[cache_key] = (result, time.time())
        return result
    except Exception:
        return ""


def load_cooldowns() -> dict[str, str]:
    try:
        f = _get_cooldowns_file()
        return json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}
    except Exception:
        return {}


def save_cooldown(skill: str) -> None:
    try:
        d = _get_data_dir()
        d.mkdir(parents=True, exist_ok=True)
        cooldowns = load_cooldowns()
        cooldowns[skill] = datetime.now(timezone.utc).isoformat()
        _get_cooldowns_file().write_text(json.dumps(cooldowns, indent=2), encoding="utf-8")
    except Exception:
        pass


def is_in_cooldown(skill: str, cooldowns: dict[str, str], cooldown_minutes: int) -> bool:
    last = cooldowns.get(skill)
    if not last:
        return False
    try:
        elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() / 60
        return elapsed < cooldown_minutes
    except Exception:
        return False


async def recommend_skill(
    context: str,
    bypass_cooldown: bool = False,
    cooldown_minutes: int = 30,
    model: str = DEFAULT_MODEL,
) -> Recommendation | None:
    catalog = load_catalog()
    if not catalog or not context.strip():
        return None
    cooldowns = {} if bypass_cooldown else load_cooldowns()
    skills_text = "\n".join(f"- {s['skill']}: {s['description']}" for s in catalog)
    prompt = (
        f"다음은 Claude Code 대화 히스토리 일부입니다:\n<transcript>\n{context}\n</transcript>\n\n"
        f"다음은 사용 가능한 스킬 목록입니다:\n<skills>\n{skills_text}\n</skills>\n\n"
        "위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.\n"
        '반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.\n'
        '{"skill": "<스킬명>", "reason": "<한 문장 이유>"}'
    )
    raw = await chat_completion(
        messages=[{"role": "user", "content": prompt}],
        model=model,
        max_completion_tokens=100,
        temperature=0.2,
    )
    rec = parse_recommendation(raw, catalog)
    if not rec:
        return None
    if not bypass_cooldown and is_in_cooldown(rec["skill"], cooldowns, cooldown_minutes):
        return None
    return rec
