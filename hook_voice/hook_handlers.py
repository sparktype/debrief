# hook_voice/hook_handlers.py
# 각 hook subcommand 구현 함수
import json
import os
import re
from pathlib import Path

_CLASSIFY_RULES_PATH = Path(__file__).parent.parent / "classify-rules.json"
_classify_rules_cache: list[dict] | None = None


def _load_classify_rules() -> list[dict]:
    global _classify_rules_cache
    if _classify_rules_cache is not None:
        return _classify_rules_cache
    try:
        data = json.loads(_CLASSIFY_RULES_PATH.read_text(encoding="utf-8"))
        _classify_rules_cache = data.get("pre_tool", [])
    except Exception:
        _classify_rules_cache = []
    return _classify_rules_cache

from .config import Config
from .player import speak_hook, speak_agent
from .summarizer import extract_summary, extract_one_liner
from .voice_router import load_voice_map, resolve_voice, resolve_voice_name, resolve_instruct, get_agent_label
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
    rules = _load_classify_rules()
    if rules:
        for rule in rules:
            if re.search(rule["pattern"], cmd, re.IGNORECASE):
                return rule["message"]
        return None
    # JSON 없을 때 하드코딩 폴백
    if re.search(r"rm\s+-rf|git\s+reset\s+--hard|DROP\s+TABLE", cmd, re.IGNORECASE):
        return "주의: 되돌릴 수 없는 작업입니다."
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd, re.IGNORECASE):
        return "빌드를 시작합니다."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd, re.IGNORECASE):
        return "테스트를 실행합니다."
    if re.search(r"npm\s+install|npm\s+ci|pip\s+install|uv\s+sync", cmd, re.IGNORECASE):
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
        await speak_hook(summary, config.voice, config.tts_speed,
                         edge_timeout=config.edge_timeout_ms / 1000)


async def handle_notification(raw: str, config: Config) -> None:
    try:
        data = json.loads(raw)
        msg = data.get("message") or data.get("title") or ""
    except Exception:
        msg = ""
    if msg and config.auto_speak:
        await speak_hook(msg, config.voice, config.tts_speed,
                         edge_timeout=config.edge_timeout_ms / 1000)


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
    voice_name = resolve_voice_name(agent_type, vm)
    label = get_agent_label(agent_type, vm)
    instruct = resolve_instruct(agent_type, vm)
    one_liner = await extract_one_liner(text, config.summary_model)
    await speak_agent(f"{label} {voice_name}입니다. {one_liner}", voice, config.supertonic_port, config.tts_speed, instruct,
                      supertonic_timeout=config.supertonic_timeout_ms / 1000)


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


async def handle_history(args: list[str], config: "Config") -> None:
    """최근 N개 발화 히스토리를 출력한다."""
    n = 10
    if args:
        try:
            n = int(args[0])
        except ValueError:
            pass
    from .last_message import _get_history_file
    hist = _get_history_file()
    if not hist.exists():
        print("발화 히스토리가 없습니다.")
        return
    lines = hist.read_text(encoding="utf-8").splitlines()
    for line in lines[-n:]:
        try:
            entry = json.loads(line)
            ts = entry.get("ts", "")[:19].replace("T", " ")
            text = entry.get("text", "")[:80]
            print(f"  {ts}  {text}")
        except Exception:
            pass


async def handle_health() -> None:
    """TTS 시스템 전체 상태를 진단하고 출력한다."""
    import os as _os
    import httpx as _httpx

    results: list[tuple[str, str]] = []

    # 1. HUB_API_KEY
    api_key = _os.environ.get("HUB_API_KEY", "")
    results.append(("HUB_API_KEY 환경변수", "OK" if api_key else "MISSING"))

    # 2. LLM API
    if api_key:
        try:
            from .llm_client import chat_completion
            resp = await chat_completion([{"role": "user", "content": "ping"}], max_tokens=1)
            results.append(("LLM API 연결", "OK" if resp is not None else "응답 없음"))
        except Exception as e:
            results.append(("LLM API 연결", f"FAIL ({type(e).__name__})"))
    else:
        results.append(("LLM API 연결", "SKIP (API 키 없음)"))

    # 3. uvicorn
    try:
        async with _httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get("http://localhost:7777/health")
            results.append(("uvicorn (7777)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})"))
    except Exception as e:
        results.append(("uvicorn (7777)", f"FAIL ({type(e).__name__})"))

    # 4. supertonic
    try:
        async with _httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get("http://localhost:7788/v1/health")
            results.append(("supertonic (7788)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})"))
    except Exception as e:
        results.append(("supertonic (7788)", f"FAIL ({type(e).__name__})"))

    # 5. spool
    from .player import SPOOL_DIR
    files = (list(SPOOL_DIR.glob("*.wav")) + list(SPOOL_DIR.glob("*.mp3"))) if SPOOL_DIR.exists() else []
    results.append(("spool 디렉토리", f"{len(files)}개 대기 ({SPOOL_DIR})"))

    print("[TTS 시스템 진단]")
    for label, status in results:
        if status.startswith("OK") or "대기" in status:
            icon = "✓"
        elif "SKIP" in status:
            icon = "!"
        else:
            icon = "✗"
        print(f"  [{icon}] {label}: {status}")


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
