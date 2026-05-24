# hook_voice/hook_handlers.py
# 각 hook subcommand 구현 함수
import json
import os
import re
from pathlib import Path

from .config import Config
from .player import speak_hook, speak_agent
from .summarizer import extract_summary, extract_one_liner
from .voice_router import load_voice_map, resolve_voice, get_agent_label
from .skill_recommender import read_recent_transcripts, recommend_skill, save_cooldown


def _derive_transcript_path() -> Path | None:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    home = os.environ.get("HOME", "")
    if not session_id or not project_dir or not home:
        return None
    slug = project_dir.replace("/", "-")
    return Path(home) / ".claude" / "projects" / slug / f"{session_id}.jsonl"


def _extract_last_assistant_text(transcript_path: Path) -> str:
    if not transcript_path.exists():
        return ""
    try:
        for line in reversed(transcript_path.read_text(encoding="utf-8").splitlines()):
            try:
                entry = json.loads(line)
                msg = entry.get("message", entry)
                if msg.get("role") != "assistant":
                    continue
                content = msg.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            if len(text) >= 20:
                                return text
                elif isinstance(content, str) and len(content) >= 20:
                    return content
            except Exception:
                pass
    except Exception:
        pass
    return ""


def _extract_agent_type_from_transcript(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        for line in reversed(path.read_text(encoding="utf-8").splitlines()):
            try:
                entry = json.loads(line)
                for block in entry.get("content", []):
                    if (
                        isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Agent"
                    ):
                        t = block.get("input", {}).get("subagent_type", "")
                        if t:
                            return t
            except Exception:
                pass
    except Exception:
        pass
    return ""


def classify_pre_tool_bash(cmd: str) -> str | None:
    if re.search(r"rm\s+-rf|git\s+reset\s+--hard|DROP\s+TABLE", cmd):
        return "주의: 되돌릴 수 없는 작업입니다."
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd):
        return "빌드를 시작합니다."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        return "테스트를 실행합니다."
    if re.search(r"npm\s+install|npm\s+ci|pip\s+install|uv\s+sync", cmd):
        return "패키지를 설치합니다."
    return None


def classify_post_tool_bash(cmd: str, output: str, exit_code: int) -> str | None:
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd):
        return "빌드 완료." if exit_code == 0 else "빌드 실패. 에러를 확인하세요."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        passed = re.search(r"(\d+)\s*(passed|passing)", output)
        failed = re.search(r"(\d+)\s*(failed|failing)", output)
        if failed and int(failed.group(1)) > 0:
            p = f", {passed.group(1)}개 통과" if passed else ""
            return f"테스트 {failed.group(1)}개 실패{p}."
        if passed:
            return f"전체 {passed.group(1)}개 통과."
    return None


async def handle_hook(raw: str, config: Config) -> None:
    text = ""
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", "")
    except Exception:
        pass
    if not text:
        tp = _derive_transcript_path()
        if tp:
            text = _extract_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        await speak_hook(summary, config.voice, config.tts_speed)


async def handle_notification(raw: str, config: Config) -> None:
    try:
        data = json.loads(raw)
        msg = data.get("message") or data.get("title") or ""
    except Exception:
        msg = ""
    if msg and config.auto_speak:
        await speak_hook(msg, config.voice, config.tts_speed)


async def handle_subagent_stop(raw: str, agent_type: str, config: Config) -> None:
    text = raw
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", raw)
        if not agent_type:
            tp = data.get("transcript_path", "")
            if tp:
                agent_type = _extract_agent_type_from_transcript(Path(tp))
    except Exception:
        pass
    if len(text) < config.min_chars:
        return
    vm = load_voice_map()
    voice = resolve_voice(agent_type, vm)
    label = get_agent_label(agent_type, vm)
    one_liner = await extract_one_liner(text, config.summary_model)
    await speak_agent(f"{label}입니다. {one_liner}", voice, config.supertonic_port, config.tts_speed)


async def handle_hook_suggest(raw: str, config: Config) -> None:
    prompt_hint = ""
    try:
        data = json.loads(raw)
        prompt = data.get("prompt", "")
        if len(prompt) >= 10:
            prompt_hint = f"\n[현재 입력]: {prompt[:200]}"
    except Exception:
        pass
    context = read_recent_transcripts() + prompt_hint
    rec = await recommend_skill(
        context,
        bypass_cooldown=False,
        cooldown_minutes=config.skill_cooldown_minutes,
        model=config.summary_model,
    )
    if rec:
        await speak_hook(f"지금 상황엔 {rec['skill']} 스킬이 유용할 것 같아요", config.voice, config.tts_speed)
        save_cooldown(rec["skill"])


async def handle_pre_tool_bash(raw: str, config: Config) -> None:
    if not config.auto_speak:
        return
    try:
        data = json.loads(raw)
        cmd = data.get("tool_input", {}).get("command", "")
    except Exception:
        return
    msg = classify_pre_tool_bash(cmd)
    if msg:
        await speak_hook(msg, config.voice, config.tts_speed)


async def handle_post_tool_bash(raw: str, config: Config) -> None:
    if not config.auto_speak:
        return
    try:
        data = json.loads(raw)
        cmd = data.get("tool_input", {}).get("command", "")
        resp = data.get("tool_response", {})
        out = resp.get("output", "")
        code = resp.get("exitCode", resp.get("exit_code", 0))
    except Exception:
        return
    msg = classify_post_tool_bash(cmd, out, code)
    if msg:
        await speak_hook(msg, config.voice, config.tts_speed)
