# hook_voice/hook_handlers.py
# 각 hook subcommand 구현 함수
import json
import os
import re
import time as _time
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
from .observability.context import get_or_create_context
from .observability.structured_log import log_event
from .observability.metrics import get_registry
from .observability.dlq import get_dlq_store
from .player import speak_hook, speak_agent, SPOOL_DIR
from .summarizer import extract_summary, extract_one_liner, rule_one_liner, select_expression_tag
from .speech.pipeline import get_default_pipeline
from .transcript_parser import get_last_assistant_text, extract_last_agent_type
from .voice_router import load_voice_map, resolve_voice, resolve_voice_name, resolve_instruct, get_agent_label, resolve_category
from .skill_recommender import read_recent_transcripts, recommend_skill, save_cooldown


def _derive_transcript_path() -> Path | None:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    home = os.environ.get("HOME", "")
    if not session_id or not project_dir or not home:
        return None
    slug = project_dir.replace("/", "-")
    return Path(home) / ".claude" / "projects" / slug / f"{session_id}.jsonl"

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
        return "빌드가 완료됐습니다." if exit_code == 0 else "빌드가 실패했습니다. 에러를 확인해 주세요."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        passed = re.search(r"(\d+)\s*(passed|passing)", output)
        failed = re.search(r"(\d+)\s*(failed|failing)", output)
        if failed and int(failed.group(1)) > 0:
            p = f", {passed.group(1)}개 통과" if passed else ""
            return f"테스트 {failed.group(1)}개 실패했습니다{p}."
        if passed:
            return f"전체 {passed.group(1)}개 통과했습니다."
    return None


async def handle_hook(raw: str, config: Config) -> None:
    hook_ctx = get_or_create_context()
    log_event("hook_start", hook_ctx, {"source": "stop_hook"})
    get_registry().record_event("hook", "stop")

    text = ""
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", "")
    except Exception:
        pass
    if not text:
        tp = _derive_transcript_path()
        if tp:
            text = get_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        if config.speech_retouch:
            pipeline = get_default_pipeline()
            speech_ctx = await pipeline.process(summary)
            summary = speech_ctx.text  # EdgeTTS는 SSML 미지원 — speech_ctx.ssml의 break 태그가 텍스트로 발화되는 것 방지
        start = _time.time()
        try:
            await speak_hook(summary, config.voice, config.tts_speed,
                             edge_timeout=config.edge_timeout_ms / 1000)
            latency_ms = (_time.time() - start) * 1000
            get_registry().record_tts_latency(latency_ms)
            log_event("tts_completed", hook_ctx, {
                "latency_ms": round(latency_ms, 1),
                "text_len": len(summary),
            })
        except Exception as exc:
            log_event("tts_failed", hook_ctx, {"error": str(exc)}, level="WARNING")
            get_dlq_store().push(
                event_id=hook_ctx.correlation_id,
                failure_stage="speak_hook",
                failure_detail=str(exc),
                raw_text=summary[:200],
                source="stop_hook",
            )


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
    hook_ctx = get_or_create_context()
    log_event("hook_start", hook_ctx, {"source": "subagent_stop", "agent_type": agent_type})
    get_registry().record_event("subagent", "stop")

    text = raw
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", raw)
        if not agent_type:
            tp = data.get("transcript_path", "")
            if tp:
                agent_type = extract_last_agent_type(Path(tp))
    except Exception:
        pass
    if len(text) < config.min_chars:
        return
    vm = load_voice_map()
    voice = resolve_voice(agent_type, vm)
    voice_name = resolve_voice_name(agent_type, vm)
    label = get_agent_label(agent_type, vm)
    instruct = resolve_instruct(agent_type, vm)
    category = resolve_category(agent_type, vm)
    steps = vm.get("supertonic", {}).get("steps", 12)
    one_liner = rule_one_liner(text)
    tag = select_expression_tag(one_liner, category)
    prefix = f"{tag} " if tag else ""
    speak_text = f"{prefix}{label} {voice_name}입니다. {one_liner}"
    start = _time.time()
    try:
        await speak_agent(speak_text, voice, config.supertonic_port, config.tts_speed, instruct,
                          steps=steps, supertonic_timeout=config.supertonic_timeout_ms / 1000)
        latency_ms = (_time.time() - start) * 1000
        get_registry().record_tts_latency(latency_ms)
        log_event("tts_completed", hook_ctx, {
            "latency_ms": round(latency_ms, 1),
            "text_len": len(speak_text),
            "agent_type": agent_type,
        })
    except Exception as exc:
        log_event("tts_failed", hook_ctx, {"error": str(exc), "agent_type": agent_type}, level="WARNING")
        get_dlq_store().push(
            event_id=hook_ctx.correlation_id,
            failure_stage="speak_agent",
            failure_detail=str(exc),
            raw_text=speak_text[:200],
            source="subagent_stop",
        )


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
    import asyncio as _asyncio
    import os as _os
    import httpx as _httpx

    results: list[tuple[str, str]] = []

    # 1. HUB_API_KEY (동기)
    api_key = _os.environ.get("HUB_API_KEY", "")
    results.append(("HUB_API_KEY 환경변수", "OK" if api_key else "MISSING"))

    # 2~5. LLM API · EdgeTTS · uvicorn · supertonic — 병렬 실행
    async def _check_llm() -> tuple[str, str]:
        if not api_key:
            return ("LLM API 연결", "SKIP (API 키 없음)")
        try:
            from .llm_client import chat_completion
            resp = await chat_completion([{"role": "user", "content": "ping"}], max_tokens=1)
            return ("LLM API 연결", "OK" if resp else "FAIL (빈 응답)")
        except Exception as e:
            return ("LLM API 연결", f"FAIL ({type(e).__name__})")

    async def _check_edgetts() -> tuple[str, str]:
        try:
            async with _httpx.AsyncClient(timeout=3.0, verify=False) as client:
                r = await client.get("https://speech.platform.bing.com/")
                return ("EdgeTTS 연결", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})")
        except Exception as e:
            return ("EdgeTTS 연결", f"FAIL ({type(e).__name__})")

    async def _check_uvicorn() -> tuple[str, str]:
        try:
            async with _httpx.AsyncClient(timeout=2.0) as client:
                r = await client.get("http://localhost:7777/health")
                return ("uvicorn (7777)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})")
        except Exception as e:
            return ("uvicorn (7777)", f"FAIL ({type(e).__name__})")

    async def _check_supertonic() -> tuple[str, str]:
        try:
            async with _httpx.AsyncClient(timeout=2.0) as client:
                r = await client.get("http://localhost:7788/v1/health")
                return ("supertonic (7788)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})")
        except Exception as e:
            return ("supertonic (7788)", f"FAIL ({type(e).__name__})")

    parallel_results = await _asyncio.gather(
        _check_llm(),
        _check_edgetts(),
        _check_uvicorn(),
        _check_supertonic(),
    )
    results.extend(parallel_results)

    # 6. spool (동기)
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


async def handle_control(action: str) -> None:
    """TTS 재생 제어 — pause/resume/flush/skip."""
    import os as _os
    import signal as _signal
    import sys as _sys

    _VALID_ACTIONS = {"pause", "resume", "flush", "skip"}
    if action not in _VALID_ACTIONS:
        print("사용법: hook_voice control [pause|resume|flush|skip]", file=_sys.stderr)
        _sys.exit(1)

    if action == "flush":
        removed = 0
        for f in list(SPOOL_DIR.glob("*.wav")) + list(SPOOL_DIR.glob("*.mp3")):
            try:
                f.unlink()
                removed += 1
            except Exception:
                pass
        print(f"큐를 비웠습니다. ({removed}개 제거)")
        return

    pid_file = SPOOL_DIR / ".player.pid"
    if not pid_file.exists():
        print("현재 재생 중인 TTS가 없습니다.")
        return

    try:
        pid = int(pid_file.read_text().strip())
    except Exception:
        print("PID 파일을 읽을 수 없습니다.")
        return

    try:
        if action == "pause":
            _os.kill(pid, _signal.SIGSTOP)
            print(f"TTS를 일시정지했습니다. (PID {pid})")
        elif action == "resume":
            _os.kill(pid, _signal.SIGCONT)
            print(f"TTS 재생을 재개했습니다. (PID {pid})")
        elif action == "skip":
            _os.kill(pid, _signal.SIGKILL)
            pid_file.unlink(missing_ok=True)
            print(f"현재 트랙을 건너뛰었습니다. (PID {pid})")
    except ProcessLookupError:
        print("재생 프로세스가 이미 종료된 상태입니다.")
        pid_file.unlink(missing_ok=True)
    except PermissionError as e:
        print(f"권한 오류: {e}", file=_sys.stderr)
        _sys.exit(1)


async def handle_config(args: list[str], config_path: "Path") -> None:
    """CLI 설정 관리 — get/set/list/reset."""
    import sys as _sys
    import json as _json
    from .config import load_config, _KEY_MAP

    if not args or args[0] == "list":
        cfg = load_config(config_path)
        print("[현재 설정]")
        for json_key, py_key in _KEY_MAP.items():
            print(f"  {json_key} = {getattr(cfg, py_key)}")
        return

    if args[0] == "get" and len(args) == 2:
        json_key = args[1]
        if json_key not in _KEY_MAP:
            print(f"알 수 없는 키: {json_key}. 사용 가능: {', '.join(_KEY_MAP)}", file=_sys.stderr)
            _sys.exit(1)
        cfg = load_config(config_path)
        print(getattr(cfg, _KEY_MAP[json_key]))
        return

    if args[0] == "set" and len(args) == 3:
        json_key, raw_val = args[1], args[2]
        if json_key not in _KEY_MAP:
            print(f"알 수 없는 키: {json_key}. 사용 가능: {', '.join(_KEY_MAP)}", file=_sys.stderr)
            _sys.exit(1)
        data = _json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
        if raw_val.lower() == "true":
            val: object = True
        elif raw_val.lower() == "false":
            val = False
        else:
            try:
                val = int(raw_val)
            except ValueError:
                try:
                    val = float(raw_val)
                except ValueError:
                    val = raw_val
        data[json_key] = val
        config_path.write_text(_json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  {json_key} = {val}  (저장됨)")
        return

    if args[0] == "reset":
        if config_path.exists():
            config_path.unlink()
        print("설정을 기본값으로 초기화했습니다.")
        return

    print("사용법: hook_voice config [list|get <key>|set <key> <val>|reset]", file=_sys.stderr)
    _sys.exit(1)


async def handle_grafana(args: list[str], config_path: "Path | None" = None) -> None:
    """grafana 서브커맨드 — 알럿 감시 목록 관리."""
    import json
    from .config import _find_default_config, _VOICE_JSON

    target = config_path or _find_default_config() or _VOICE_JSON

    def _load_raw() -> dict:
        if not target.exists():
            return {}
        try:
            return json.loads(target.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _save_raw(data: dict) -> None:
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def _get_alerts(data: dict) -> list:
        return data.get("grafana", {}).get("alerts", [])

    def _set_alerts(data: dict, alerts: list) -> None:
        if "grafana" not in data:
            data["grafana"] = {}
        data["grafana"]["alerts"] = alerts

    if not args:
        print("Usage: python -m hook_voice grafana <list|add|remove>", flush=True)
        return

    sub = args[0]

    if sub == "list":
        data = _load_raw()
        alerts = _get_alerts(data)
        if not alerts:
            print("등록된 알럿이 없습니다.", flush=True)
        else:
            print(f"감시 중인 알럿 ({len(alerts)}개):", flush=True)
            for a in alerts:
                print(f"  - {a}", flush=True)

    elif sub == "add":
        if len(args) < 2:
            print("Usage: python -m hook_voice grafana add <알럿명>", flush=True)
            return
        name = args[1]
        data = _load_raw()
        alerts = _get_alerts(data)
        if name in alerts:
            print(f"이미 등록된 알럿입니다: {name}", flush=True)
            return
        alerts.append(name)
        _set_alerts(data, alerts)
        _save_raw(data)
        print(f"알럿 추가됨: {name}", flush=True)
        print("※ 변경 사항은 TTS supervisor 재시작 후 적용됩니다 (./server.sh restart)", flush=True)

    elif sub == "remove":
        if len(args) < 2:
            print("Usage: python -m hook_voice grafana remove <알럿명>", flush=True)
            return
        name = args[1]
        data = _load_raw()
        alerts = _get_alerts(data)
        if name not in alerts:
            print(f"등록되지 않은 알럿입니다: {name}", flush=True)
            return
        alerts.remove(name)
        _set_alerts(data, alerts)
        _save_raw(data)
        print(f"알럿 제거됨: {name}", flush=True)
        print("※ 변경 사항은 TTS supervisor 재시작 후 적용됩니다 (./server.sh restart)", flush=True)

    else:
        print(f"알 수 없는 서브커맨드: {sub}", flush=True)
