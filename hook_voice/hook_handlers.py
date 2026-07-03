# hook_voice/hook_handlers.py
# 각 hook subcommand 구현 함수
import json
import os
import re
import sys
import time as _time
from pathlib import Path

import httpx

from .hud.snapshot import load_snapshot, build_label


def _status(msg: str) -> None:
    """터미널 stderr에 chorus 상태를 출력한다."""
    print(msg, file=sys.stderr, flush=True)

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

from .config import Config, load_config
from .observability.context import get_or_create_context
from .observability.structured_log import log_event
from .observability.metrics import get_registry
from .observability.dlq import get_dlq_store
from .player import speak_hook, speak_agent, SPOOL_DIR, speak_hook_chunked, enqueue_earcon
from .summarizer import (
    extract_summary, extract_one_liner, extract_one_liner_with_tag,
    select_expression_tag, has_heavy_code, summarize_with_code_hint,
)
from .speech.pipeline import get_default_pipeline
from .transcript_parser import get_last_assistant_text, extract_last_agent_type
from .voice_router import (
    _DEFAULT_VOICE_MAP_PATH,
    load_voice_map,
    resolve_voice,
    resolve_voice_name,
    resolve_instruct,
    get_agent_label,
    resolve_category,
    resolve_voice_settings,
)
from .skill_recommender import read_recent_transcripts, recommend_skill, save_cooldown
from .event.policy import SpeechPolicy, _ERROR_RE as _POLICY_ERROR_RE
from .assist.briefing import brief_assistant_response, explain_command_failure
from .hud.snapshot import save_snapshot
from .learning.stats_store import record_playback as _record_stat, load_stats as _load_stats, clear_stats as _clear_stats, stats_file_path as _stats_file_path
from .learning.advisor import analyze as _analyze_stats


_MODE_PRESETS: dict[str, dict[str, object]] = {
    "normal": {
        "voiceMode": "normal",
        "autoSpeak": True,
        "minChars": 50,
        "ttsSpeed": 1.1,
        "speechRetouch": True,
        "bridgeEnabled": False,
        "usageTracking": True,
    },
    "focus": {
        "voiceMode": "focus",
        "autoSpeak": True,
        "minChars": 120,
        "ttsSpeed": 1.05,
        "speechRetouch": True,
        "bridgeEnabled": False,
        "usageTracking": True,
    },
    "quiet": {
        "voiceMode": "quiet",
        "autoSpeak": True,
        "minChars": 300,
        "ttsSpeed": 1.0,
        "speechRetouch": True,
        "bridgeEnabled": False,
        "usageTracking": True,
    },
    "verbose": {
        "voiceMode": "verbose",
        "autoSpeak": True,
        "minChars": 20,
        "ttsSpeed": 1.1,
        "speechRetouch": True,
        "bridgeEnabled": True,
        "bridgeThresholdMs": 120,
        "usageTracking": True,
    },
    "night": {
        "voiceMode": "night",
        "autoSpeak": True,
        "minChars": 120,
        "ttsSpeed": 0.95,
        "speechRetouch": True,
        "bridgeEnabled": False,
        "usageTracking": True,
    },
}

_VOICE_IDS = {"F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"}


def _read_json_object(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _write_json_object(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


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
        # 브리지 WAV 즉시 재생 — 요약 대기 침묵 제거 (bridge_threshold_ms를 문자 수 임계값으로 사용)
        if config.bridge_enabled and len(text) >= config.bridge_threshold_ms:
            _bridge_path = Path(__file__).parent.parent / "assets" / "bridge_thinking.wav"
            if _bridge_path.exists():
                enqueue_earcon(_bridge_path, speed=1.0)
        _status("🎙️ chorus: 요약 중...")
        is_code_heavy = has_heavy_code(text)
        used_briefing = False
        if config.assistant_tts.enabled:
            briefing = await brief_assistant_response(
                text,
                model=config.summary_model,
                timeout_ms=config.assistant_tts.llm_timeout_ms,
            )
            summary = briefing.spoken_text
            used_briefing = True
            # HUD 스냅샷 업데이트
            try:
                snap = load_snapshot(_HUD_SNAPSHOT_PATH)
                snap["last_event"] = {
                    "kind": "briefing",
                    "summary": briefing.hud_summary,
                    "ts": _time.time(),
                }
                save_snapshot(snap, _HUD_SNAPSHOT_PATH)
            except Exception:
                pass
        elif is_code_heavy:
            summary = summarize_with_code_hint(text)
        else:
            summary = await extract_summary(text, config.summary_model)
        if config.speech_retouch and not is_code_heavy and not used_briefing:
            _status("🗣️ chorus: 음성 정제 중...")
            pipeline = get_default_pipeline()
            speech_ctx = await pipeline.process(summary)
            summary = speech_ctx.text  # SSML break 태그가 텍스트로 발화되는 것 방지

        # SmartTTSRouter — 응답 타입 기반 발화 정책 결정
        is_error = bool(_POLICY_ERROR_RE.search(summary))
        dec = SpeechPolicy.decide(summary, is_error=is_error)
        if dec.mode == "skip":
            return
        if dec.mode == "earcon_only":
            _earcon_path = Path(__file__).parent.parent / "assets" / "earcon_switch.wav"
            if _earcon_path.exists():
                enqueue_earcon(_earcon_path, speed=config.tts_speed)
            return

        session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        monitor_flag = Path(f"/tmp/tts-monitor-{session_id}") if session_id else None
        use_reviewer = bool(monitor_flag and monitor_flag.exists())
        failure_stage = "speak_agent_monitor" if use_reviewer else "speak_hook"

        start = _time.time()
        _speech_mode = dec.mode  # 통계용
        try:
            _status("🗣️ chorus: 음성 생성 중...")
            if use_reviewer:
                vm = load_voice_map()
                settings = resolve_voice_settings("code-reviewer", vm)
                instruct = resolve_instruct("code-reviewer", vm)
                monitor_flag.unlink(missing_ok=True)
                await speak_agent(
                    summary, "M2",
                    port=config.supertonic_port, speed=config.tts_speed,
                    instruct=instruct,
                    steps=settings["steps"],
                    synth_speed=settings["synth_speed"],
                    supertonic_timeout=config.supertonic_timeout_ms / 1000,
                )
            else:
                await speak_hook_chunked(summary, config.tts_speed)
            _status("▶️ chorus: 재생 중")
            latency_ms = (_time.time() - start) * 1000
            get_registry().record_tts_latency(latency_ms)
            log_event("tts_completed", hook_ctx, {
                "latency_ms": round(latency_ms, 1),
                "text_len": len(summary),
            })
            if config.usage_tracking:
                _record_stat(
                    agent_type="default",
                    mode=_speech_mode,
                    priority=dec.priority,
                    completed=True,
                    duration_secs=latency_ms / 1000,
                )
        except Exception as exc:
            _elapsed_ms = (_time.time() - start) * 1000
            _status(f"⚠️ chorus: 음성 실패 ({type(exc).__name__})")
            log_event("tts_failed", hook_ctx, {"error": str(exc)}, level="WARNING")
            get_dlq_store().push(
                event_id=hook_ctx.correlation_id,
                failure_stage=failure_stage,
                failure_detail=str(exc),
                raw_text=summary[:200],
                source="stop_hook",
            )
            if config.usage_tracking:
                _record_stat(
                    agent_type="default",
                    mode=_speech_mode,
                    priority=dec.priority,
                    completed=False,
                    duration_secs=_elapsed_ms / 1000,
                )


async def handle_notification(raw: str, config: Config) -> None:
    try:
        data = json.loads(raw)
        msg = data.get("message") or data.get("title") or ""
    except Exception:
        msg = ""
    if msg and config.auto_speak:
        await speak_hook(msg, config.tts_speed)


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
    settings = resolve_voice_settings(agent_type, vm)
    steps = settings["steps"]
    synth_speed = settings["synth_speed"]
    one_liner, tag = await extract_one_liner_with_tag(text, category, model=config.summary_model)

    # 에이전트 전환 earcon
    _earcon_cfg = vm.get("earcon", {})
    if _earcon_cfg.get("enabled", False):
        _earcon_path = Path(__file__).parent.parent / _earcon_cfg.get("agent_switch", "assets/earcon_switch.wav")
        enqueue_earcon(_earcon_path, speed=config.tts_speed)

    # expressionLevel에 따라 감정 태그 결정
    # Supertonic 3 스펙: 태그는 발화 맨 앞에 위치할 때 효과가 가장 명확함
    # 공식 문서화 태그: breath·laugh·sigh (나머지 7종은 동작하나 실험적)
    _OFFICIAL_TAGS = frozenset({"breath", "laugh", "sigh"})
    expr = config.expression_level
    if expr == "off":
        effective_tag = ""           # 태그 완전 제거
    elif expr == "low":
        effective_tag = "<breath>"   # 공식 지원 중 가장 중립적인 호흡
    elif expr == "high":
        effective_tag = tag if tag else "<breath>"  # LLM 선택 10종 그대로
    else:                            # "normal" — 공식 지원 3종 내로 제한
        if tag:
            tag_name = tag.strip("<>")
            effective_tag = tag if tag_name in _OFFICIAL_TAGS else "<breath>"
        else:
            effective_tag = "<breath>"

    # 태그를 발화 맨 앞에 위치시켜 Supertonic 효과를 최대화
    if effective_tag:
        speak_text = f"{effective_tag} {label} {voice_name}입니다. {one_liner}"
    else:
        speak_text = f"{label} {voice_name}입니다. {one_liner}"
    start = _time.time()
    try:
        await speak_agent(speak_text, voice, config.supertonic_port, config.tts_speed, instruct,
                          steps=steps, synth_speed=synth_speed, supertonic_timeout=config.supertonic_timeout_ms / 1000)
        latency_ms = (_time.time() - start) * 1000
        get_registry().record_tts_latency(latency_ms)
        log_event("tts_completed", hook_ctx, {
            "latency_ms": round(latency_ms, 1),
            "text_len": len(speak_text),
            "agent_type": agent_type,
        })
        if config.usage_tracking:
            _record_stat(
                agent_type=agent_type or "default",
                mode="full",
                priority="NORMAL",
                completed=True,
                duration_secs=latency_ms / 1000,
            )
    except Exception as exc:
        _elapsed_ms = (_time.time() - start) * 1000
        log_event("tts_failed", hook_ctx, {"error": str(exc), "agent_type": agent_type}, level="WARNING")
        get_dlq_store().push(
            event_id=hook_ctx.correlation_id,
            failure_stage="speak_agent",
            failure_detail=str(exc),
            raw_text=speak_text[:200],
            source="subagent_stop",
        )
        if config.usage_tracking:
            _record_stat(
                agent_type=agent_type or "default",
                mode="full",
                priority="NORMAL",
                completed=False,
                duration_secs=_elapsed_ms / 1000,
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
        await speak_hook(msg, config.tts_speed)


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

    # 1. AI_API_KEY (동기)
    api_key = _os.environ.get("AI_API_KEY", "") or _os.environ.get("HUB_API_KEY", "")
    results.append(("AI_API_KEY 환경변수", "OK" if api_key else "MISSING"))

    # 2~4. LLM API · uvicorn · supertonic — 병렬 실행
    async def _check_llm() -> tuple[str, str]:
        if not api_key:
            return ("LLM API 연결", "SKIP (API 키 없음)")
        try:
            from .llm_client import chat_completion
            resp = await chat_completion([{"role": "user", "content": "ping"}], max_tokens=1)
            return ("LLM API 연결", "OK" if resp else "FAIL (빈 응답)")
        except Exception as e:
            return ("LLM API 연결", f"FAIL ({type(e).__name__})")

    async def _check_server() -> tuple[str, str]:
        try:
            async with _httpx.AsyncClient(timeout=2.0) as client:
                r = await client.get("http://localhost:7777/health")
                return ("서버 (7777)", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})")
        except Exception as e:
            return ("서버 (7777)", f"FAIL ({type(e).__name__})")

    async def _check_tts() -> tuple[str, str]:
        try:
            async with _httpx.AsyncClient(timeout=2.0) as client:
                r = await client.get("http://localhost:7777/v1/health")
                return ("TTS /v1/health", f"OK ({r.status_code})" if r.is_success else f"FAIL ({r.status_code})")
        except Exception as e:
            return ("TTS /v1/health", f"FAIL ({type(e).__name__})")

    parallel_results = await _asyncio.gather(
        _check_llm(),
        _check_server(),
        _check_tts(),
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

    # 실패 명령: LLM 설명 생성 (fail-open — 실패해도 hook 지연 없음)
    if code != 0 and config.assistant_tts.failure_explain:
        explanation = await explain_command_failure(
            cmd, out, code,
            model=config.summary_model,
            timeout_ms=config.assistant_tts.llm_timeout_ms,
        )
        if explanation:
            # HUD 스냅샷에 failure 이벤트 기록
            try:
                snap = load_snapshot(_HUD_SNAPSHOT_PATH)
                snap["last_event"] = {
                    "kind": "failure",
                    "summary": explanation[:60],
                    "ts": _time.time(),
                }
                save_snapshot(snap, _HUD_SNAPSHOT_PATH)
            except Exception:
                pass
            await speak_hook(explanation, config.tts_speed)
            return

    # 성공 또는 실패 설명 비활성화: 기존 규칙 기반 경로
    msg = classify_post_tool_bash(cmd, out, code)
    if msg:
        await speak_hook(msg, config.tts_speed)


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


_EXPRESSION_LEVELS = {
    "off":    "감정 태그 없음 — 태그를 완전히 제거합니다. 가장 단조롭지만 가장 안정적입니다.",
    "low":    "최소 표현 — Supertonic 공식 지원 태그(<breath>)만 사용합니다. 자연스러운 시작 호흡.",
    "normal": "표준 (기본값) — 공식 지원 3종(<breath>·<laugh>·<sigh>) 내에서 내용에 맞게 선택합니다.",
    "high":   "전체 표현 — LLM이 10종 태그 중 내용에 가장 어울리는 것을 자유롭게 선택합니다. (실험적)",
}


async def handle_expression(args: list[str], config_path: "Path") -> None:
    """서브에이전트 발화의 감정 표현 수준을 조절한다.

    expression show               — 현재 설정 확인
    expression set <off|low|normal> — 레벨 변경
    expression list               — 레벨 설명 목록
    """
    import sys as _sys
    import json as _json

    action = args[0] if args else "show"

    if action == "list":
        print("감정 표현 레벨:")
        for level, desc in _EXPRESSION_LEVELS.items():
            print(f"  {level:8s} — {desc}")
        return

    if action == "show":
        data = _read_json_object(config_path)
        current = data.get("expressionLevel", "normal")
        desc = _EXPRESSION_LEVELS.get(current, "")
        print(f"현재 expressionLevel: {current}")
        if desc:
            print(f"  {desc}")
        return

    if action == "set" and len(args) == 2:
        level = args[1].lower()
        if level not in _EXPRESSION_LEVELS:
            print(f"알 수 없는 레벨: {level}. 사용 가능: {', '.join(_EXPRESSION_LEVELS)}", file=_sys.stderr)
            _sys.exit(1)
        data = _read_json_object(config_path)
        data["expressionLevel"] = level
        _write_json_object(config_path, data)
        print(f"expressionLevel = {level} (저장됨)")
        print(f"  {_EXPRESSION_LEVELS[level]}")
        return

    print("사용법: hook_voice setup expression [show|list|set <off|low|normal|high>]", file=_sys.stderr)
    _sys.exit(1)


async def handle_mode(args: list[str], config_path: "Path") -> None:
    """상황별 음성 프리셋을 .voice.json에 적용한다."""
    import sys as _sys

    action = args[0] if args else "show"

    if action == "list":
        print("사용 가능한 모드:")
        for name in _MODE_PRESETS:
            print(f"  - {name}")
        return

    if action == "show":
        data = _read_json_object(config_path)
        current = data.get("voiceMode", "normal")
        print(f"현재 모드: {current}")
        return

    if action == "set" and len(args) == 2:
        mode = args[1]
        preset = _MODE_PRESETS.get(mode)
        if preset is None:
            print(f"알 수 없는 모드: {mode}. 사용 가능: {', '.join(_MODE_PRESETS)}", file=_sys.stderr)
            _sys.exit(1)
        data = _read_json_object(config_path)
        data.update(preset)
        _write_json_object(config_path, data)
        print(f"voiceMode = {mode} (저장됨)")
        print(f"  minChars={data['minChars']}, ttsSpeed={data['ttsSpeed']}, bridgeEnabled={data['bridgeEnabled']}")
        return

    print("사용법: hook_voice mode [show|list|set <normal|focus|quiet|verbose|night>]", file=_sys.stderr)
    _sys.exit(1)


async def handle_setup(args: list[str], config_path: "Path", voice_map_path: "Path" = _DEFAULT_VOICE_MAP_PATH) -> None:
    """초기 설정과 서브에이전트별 목소리 매핑을 관리한다."""
    import sys as _sys

    section = args[0] if args else "status"

    if section == "status":
        cfg = load_config(config_path)
        vm = load_voice_map(voice_map_path)
        print("[chorus setup]")
        print(f"  config: {config_path}")
        print(f"  voiceMode: {cfg.voice_mode}")
        print(f"  autoSpeak: {cfg.auto_speak}")
        print(f"  minChars: {cfg.min_chars}")
        print(f"  ttsSpeed: {cfg.tts_speed}")
        print(f"  expressionLevel: {cfg.expression_level}")
        print(f"  voice-map: {voice_map_path}")
        print("  agent voices:")
        for category, voice_id in sorted(vm.get("voices", {}).items()):
            voice_name = vm.get("voice_names", {}).get(voice_id, voice_id)
            print(f"    {category}: {voice_id} ({voice_name})")
        return

    if section == "defaults":
        data = _read_json_object(config_path)
        for key, value in _MODE_PRESETS["normal"].items():
            data.setdefault(key, value)
        data.setdefault("summaryModel", "gemini-3.5-flash")
        data.setdefault("resumeThreshold", 0.0)
        data.setdefault("stt", {"enabled": False, "vadInterrupt": False})
        _write_json_object(config_path, data)
        print(f"기본 설정을 준비했습니다: {config_path}")
        return

    if section == "mode":
        await handle_mode(args[1:] or ["show"], config_path)
        return

    if section == "expression":
        await handle_expression(args[1:], config_path)
        return

    if section != "voice":
        print(
            "사용법: hook_voice setup [status|defaults|mode ...|expression ...|voice list|voice set <category> <voiceId>|voice speed <voiceId> <speed>|voice steps <voiceId> <steps>]",
            file=_sys.stderr,
        )
        _sys.exit(1)

    sub = args[1] if len(args) > 1 else "list"
    vm = _read_json_object(voice_map_path)
    if not vm:
        vm = load_voice_map(voice_map_path)  # fallback
    vm.setdefault("voices", {})
    vm.setdefault("voice_names", {})
    vm.setdefault("voice_settings", {})
    vm.setdefault("categories", {})

    if sub == "list":
        print("[서브에이전트 목소리]")
        for category, voice_id in sorted(vm.get("voices", {}).items()):
            voice_name = vm.get("voice_names", {}).get(voice_id, voice_id)
            agents = ", ".join(vm.get("categories", {}).get(category, [])[:4])
            suffix = f" — {agents}" if agents else ""
            print(f"  {category}: {voice_id} ({voice_name}){suffix}")
        print("[사용 가능한 voiceId]")
        for voice_id in sorted(_VOICE_IDS):
            print(f"  {voice_id}: {vm.get('voice_names', {}).get(voice_id, voice_id)}")
        return

    if sub == "set" and len(args) == 4:
        category, voice_id = args[2], args[3].upper()
        if voice_id not in _VOICE_IDS:
            print(f"알 수 없는 voiceId: {voice_id}. 사용 가능: {', '.join(sorted(_VOICE_IDS))}", file=_sys.stderr)
            _sys.exit(1)
        if category not in vm.get("voices", {}):
            print(f"알 수 없는 category: {category}. 사용 가능: {', '.join(sorted(vm.get('voices', {})))}", file=_sys.stderr)
            _sys.exit(1)
        vm["voices"][category] = voice_id
        _write_json_object(voice_map_path, vm)
        voice_name = vm.get("voice_names", {}).get(voice_id, voice_id)
        print(f"{category} voice = {voice_id} ({voice_name}) (저장됨)")
        return

    if sub == "speed" and len(args) == 4:
        voice_id, raw_speed = args[2].upper(), args[3]
        if voice_id not in _VOICE_IDS:
            print(f"알 수 없는 voiceId: {voice_id}. 사용 가능: {', '.join(sorted(_VOICE_IDS))}", file=_sys.stderr)
            _sys.exit(1)
        try:
            speed = float(raw_speed)
        except ValueError:
            print("speed는 숫자여야 합니다.", file=_sys.stderr)
            _sys.exit(1)
        if speed <= 0:
            print("speed는 0보다 커야 합니다.", file=_sys.stderr)
            _sys.exit(1)
        vm["voice_settings"].setdefault(voice_id, {})["synth_speed"] = speed
        _write_json_object(voice_map_path, vm)
        print(f"{voice_id} synth_speed = {speed} (저장됨)")
        return

    if sub == "steps" and len(args) == 4:
        voice_id, raw_steps = args[2].upper(), args[3]
        if voice_id not in _VOICE_IDS:
            print(f"알 수 없는 voiceId: {voice_id}. 사용 가능: {', '.join(sorted(_VOICE_IDS))}", file=_sys.stderr)
            _sys.exit(1)
        try:
            steps = int(raw_steps)
        except ValueError:
            print("steps는 정수여야 합니다.", file=_sys.stderr)
            _sys.exit(1)
        if steps < 1:
            print("steps는 1 이상이어야 합니다.", file=_sys.stderr)
            _sys.exit(1)
        vm["voice_settings"].setdefault(voice_id, {})["steps"] = steps
        _write_json_object(voice_map_path, vm)
        print(f"{voice_id} steps = {steps} (저장됨)")
        return

    print(
        "사용법: hook_voice setup voice [list|set <category> <voiceId>|speed <voiceId> <speed>|steps <voiceId> <steps>]",
        file=_sys.stderr,
    )
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


async def handle_voice_test(args: list[str], config: Config) -> None:
    """샘플 텍스트로 TTS를 생성하고 재생한다."""
    voice_id = args[0] if args else None
    text = args[1] if len(args) > 1 else "안녕하세요. 코러스 음성 테스트입니다."
    print(f"[voice test] 텍스트: {text!r}", flush=True)
    if voice_id:
        print(f"[voice test] 목소리: {voice_id}", flush=True)
    try:
        await speak_hook_chunked(text, speed=config.tts_speed)
        print("[voice test] 완료. 음성이 재생 대기열에 추가됐습니다.", flush=True)
    except Exception as e:
        print(f"[voice test] 실패: {e}", flush=True)


async def handle_doctor(config: Config) -> None:
    """TTS 시스템 전체를 진단한다 (handle_health 확장)."""
    await handle_health()
    print("\n[doctor] 음성 생성 자가 테스트 중...", flush=True)
    try:
        await speak_hook_chunked("닥터 체크 완료입니다.", speed=config.tts_speed)
        print("[doctor] ✓ TTS 생성 및 스풀 enqueue 성공", flush=True)
    except Exception as e:
        print(f"[doctor] ✗ TTS 생성 실패: {e}", flush=True)


async def handle_pre_tool_monitor(raw: str) -> None:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session_id:
        return
    Path(f"/tmp/tts-monitor-{session_id}").touch()


async def handle_suggest_config(config: Config) -> None:
    """사용 통계를 분석해 .voice.json 개선안을 제안한다."""
    stats = _load_stats()
    stats_path = _stats_file_path()
    print(f"[suggest-config] 통계 파일: {stats_path} ({len(stats)}건)", flush=True)

    if len(stats) < 10:
        print(
            f"[suggest-config] 데이터가 부족합니다 ({len(stats)}건). "
            "최소 10건의 TTS 발화 후 다시 실행해 주세요.",
            flush=True,
        )
        return

    suggestions = _analyze_stats(stats, current_speed=config.tts_speed)
    if not suggestions:
        print("[suggest-config] 현재 설정이 사용 패턴에 잘 맞습니다. 제안 사항이 없습니다.", flush=True)
        return

    print(f"[suggest-config] {len(suggestions)}개 제안이 있습니다.\n", flush=True)
    for i, sug in enumerate(suggestions, 1):
        current_str = f"{sug.current}" if sug.current is not None else "(현재값 미확인)"
        print(
            f"  [{i}] {sug.key}\n"
            f"      현재: {current_str}  →  권장: {sug.recommended}\n"
            f"      이유: {sug.reason}\n",
            flush=True,
        )
    print(
        "적용하려면 .voice.json을 직접 편집하거나 다음 명령을 사용하세요.",
        flush=True,
    )
    for sug in suggestions:
        if sug.current != sug.recommended:  # info-only Suggestion은 명령 안내 생략
            print(f"  python -m hook_voice config set {sug.key} {sug.recommended}", flush=True)


async def handle_privacy(args: list[str], config: Config) -> None:
    """사용 통계 데이터를 관리한다.

    privacy clear  — 모든 통계 데이터를 삭제한다
    privacy status — 통계 파일 경로와 크기를 출력한다
    """
    sub = args[0] if args else ""
    stats_path = _stats_file_path()

    if sub == "clear":
        deleted = _clear_stats()
        if deleted > 0:
            print(f"[privacy] 통계 데이터 {deleted}건이 삭제됐습니다. ({stats_path})", flush=True)
        else:
            print(f"[privacy] 삭제할 통계 데이터가 없습니다. ({stats_path})", flush=True)
    elif sub == "status":
        if stats_path.exists():
            size_kb = stats_path.stat().st_size / 1024
            count = len(_load_stats())
            print(
                f"[privacy] 통계 파일: {stats_path}\n"
                f"          항목 수: {count}건 ({size_kb:.1f} KB)",
                flush=True,
            )
        else:
            print(f"[privacy] 통계 파일 없음 ({stats_path})", flush=True)
    else:
        print(
            "사용법\n"
            "  python -m hook_voice privacy clear   — 모든 통계 삭제\n"
            "  python -m hook_voice privacy status  — 통계 파일 정보 확인",
            flush=True,
        )


async def handle_mute(config_path: "Path") -> None:
    """autoSpeak를 토글해 음성을 켜거나 끈다.

    현재 값이 true이면 false로, false이면 true로 변경한다.
    변경 후 음성으로 상태를 안내한다 (mute 해제 시에만).
    """
    import json as _json

    data: dict = {}
    if config_path.exists():
        try:
            data = _json.loads(config_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}

    current = data.get("autoSpeak", True)
    new_val = not current
    data["autoSpeak"] = new_val

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(_json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    if new_val:
        print("🔊 chorus: 음성이 활성화됐습니다.", flush=True)
        # 음소거 해제 시 음성으로도 안내
        try:
            from .config import load_config
            cfg = load_config(config_path)
            await speak_hook_chunked("음소거가 해제됐습니다.", cfg.tts_speed)
        except Exception:
            pass
    else:
        print("🔇 chorus: 음성이 음소거됐습니다.", flush=True)


_HUD_API_URL = "http://127.0.0.1:7777/chorus/hud"
_HUD_TIMEOUT = 0.25  # 250ms
_HUD_SNAPSHOT_PATH = Path.home() / ".local" / "share" / "chorus" / "hud.json"


async def handle_hud_label() -> None:
    """HUD 레이블을 JSON으로 출력한다.

    폴백 체인:
      1. GET /chorus/hud (timeout 250ms)
      2. ~/.local/share/chorus/hud.json 스냅샷
      3. {"label": "chorus offline"}
    """
    # 1단계: API
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(_HUD_API_URL, timeout=_HUD_TIMEOUT)
            data = resp.json()
            label = data.get("label", "")
            print(json.dumps({"label": label}), flush=True)
            return
    except Exception:
        pass

    # 2단계: 스냅샷 파일 존재 확인 후 로드
    if _HUD_SNAPSHOT_PATH.exists():
        snapshot = load_snapshot(_HUD_SNAPSHOT_PATH)
        label = build_label(snapshot)
        print(json.dumps({"label": label}), flush=True)
        return

    # 3단계: 파일 없으면 offline
    print(json.dumps({"label": "chorus offline"}), flush=True)
