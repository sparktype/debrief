from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Mapping
from urllib.request import urlopen

from .runtime_paths import RuntimePaths, atomic_write_json

LAUNCHAGENT_LABEL = "io.chorus.server"
LEGACY_LAUNCHAGENT_LABEL = "com.voice-persona.tts-server"
PRESETS: dict[str, dict[str, object]] = {
    "local": {
        "autoSpeak": True,
        "externalLlm": False,
        "usageTracking": False,
        "toolEventSpeech": "failures",
        "assistantTts": {"enabled": False, "failureExplain": False, "riskExplain": False, "promptAdvice": False},
    },
    "standard": {
        "autoSpeak": True,
        "externalLlm": True,
        "externalFeatures": ["stop_summary"],
        "usageTracking": False,
        "toolEventSpeech": "failures",
        "assistantTts": {"enabled": True, "failureExplain": False, "riskExplain": False, "promptAdvice": False},
    },
    "detailed": {
        "autoSpeak": True,
        "externalLlm": True,
        "externalFeatures": ["stop_summary", "failure_explain", "prompt_advice"],
        "usageTracking": True,
        "toolEventSpeech": "build_test_risk_failure",
        "assistantTts": {"enabled": True, "failureExplain": True, "riskExplain": True, "promptAdvice": True},
    },
}
MODE_PRESETS: dict[str, dict[str, object]] = {
    "normal": {"voiceMode": "normal", "minChars": 50, "ttsSpeed": 1.1, "bridgeEnabled": False},
    "focus": {"voiceMode": "focus", "minChars": 120, "ttsSpeed": 1.05, "bridgeEnabled": False},
    "quiet": {"voiceMode": "quiet", "minChars": 300, "ttsSpeed": 1.0, "bridgeEnabled": False},
    "verbose": {"voiceMode": "verbose", "minChars": 20, "ttsSpeed": 1.1, "bridgeEnabled": True},
    "night": {"voiceMode": "night", "minChars": 120, "ttsSpeed": 0.95, "bridgeEnabled": False},
}


class ReleaseValidationError(RuntimeError):
    pass


@dataclass(frozen=True)
class InstallResult:
    version: str
    release: Path
    previous: Path | None


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str
    recovery: str | None = None


def validate_release(release: Path) -> None:
    required = [release / "hook_voice/__init__.py", release / "tts_server/__init__.py"]
    missing = [str(path.relative_to(release)) for path in required if not path.exists()]
    if missing:
        raise ReleaseValidationError(f"missing runtime files: {', '.join(missing)}")
    try:
        for path in list((release / "hook_voice").rglob("*.py")) + list((release / "tts_server").rglob("*.py")):
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
    except (OSError, SyntaxError) as error:
        raise ReleaseValidationError(f"runtime compilation failed: {error}") from error


def install_release(source: Path, version: str, paths: RuntimePaths) -> InstallResult:
    paths.releases.mkdir(parents=True, exist_ok=True)
    previous = paths.current.resolve() if paths.current.exists() else None
    destination = paths.releases / version
    if previous == destination and destination.exists():
        validate_release(destination)
        return InstallResult(version, destination, previous)
    staging = paths.releases / f".{version}.{uuid.uuid4().hex}.staging"
    next_link = paths.runtime_dir / ".current.next"
    try:
        shutil.copytree(source, staging)
        validate_release(staging)
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(staging, destination)
        next_link.unlink(missing_ok=True)
        next_link.symlink_to(destination)
        os.replace(next_link, paths.current)
        paths.logs.mkdir(parents=True, exist_ok=True)
        return InstallResult(version, destination, previous)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        next_link.unlink(missing_ok=True)


def render_launchagent(paths: RuntimePaths, python: Path | None = None) -> str:
    executable = python or paths.runtime_dir / "venv/bin/python"
    log = paths.logs / "server.log"
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LAUNCHAGENT_LABEL}</string>
<key>ProgramArguments</key><array><string>{executable}</string><string>-m</string><string>tts_server.supervisor</string></array>
<key>WorkingDirectory</key><string>{paths.current}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>StandardOutPath</key><string>{log}</string><key>StandardErrorPath</key><string>{log}</string>
<key>EnvironmentVariables</key><dict><key>CHORUS_DATA_DIR</key><string>{paths.data_dir}</string><key>PYTHONPATH</key><string>{paths.current}</string></dict>
</dict></plist>\n'''


def ensure_runtime_environment(
    paths: RuntimePaths,
    release: Path,
    *,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> Path:
    requirements = release / "requirements.txt"
    if not requirements.exists():
        raise ReleaseValidationError("missing runtime requirements.txt")
    venv = paths.runtime_dir / "venv"
    python = venv / "bin/python"
    if not python.exists():
        run([sys.executable, "-m", "venv", str(venv)], check=True)
    run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(requirements)], check=True)
    result = run(
        [str(python), "-c", "import fastapi, httpx, numpy, soundfile, supertonic"],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise ReleaseValidationError(result.stderr.strip() or "runtime dependency import failed")
    return python


def install_launchagent(paths: RuntimePaths, *, home: Path | None = None, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Path:
    user_home = home or Path.home()
    plist = user_home / "Library/LaunchAgents" / f"{LAUNCHAGENT_LABEL}.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    temporary = plist.with_suffix(".plist.tmp")
    temporary.write_text(render_launchagent(paths), encoding="utf-8")
    os.replace(temporary, plist)
    run(["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCHAGENT_LABEL}"], capture_output=True)
    run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], capture_output=True)
    return plist


def service_action(action: str, *, home: Path | None = None, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
    if action not in {"start", "stop", "restart"}:
        raise ValueError(f"unknown service action: {action}")
    user_home = home or Path.home()
    plist = user_home / "Library/LaunchAgents" / f"{LAUNCHAGENT_LABEL}.plist"
    domain = f"gui/{os.getuid()}/{LAUNCHAGENT_LABEL}"
    if action in {"stop", "restart"}:
        run(["launchctl", "bootout", domain], capture_output=True)
    if action in {"start", "restart"}:
        if not plist.exists():
            raise FileNotFoundError(f"LaunchAgent가 없습니다: {plist}. chorus-runtime install을 실행하세요.")
        run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)


def uninstall_runtime(paths: RuntimePaths, *, purge: bool = False, home: Path | None = None, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
    user_home = home or Path.home()
    plist = user_home / "Library/LaunchAgents" / f"{LAUNCHAGENT_LABEL}.plist"
    run(["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCHAGENT_LABEL}"], capture_output=True)
    plist.unlink(missing_ok=True)
    if paths.runtime_dir.exists():
        shutil.rmtree(paths.runtime_dir)
    if purge and paths.data_dir.exists():
        shutil.rmtree(paths.data_dir)


def daemon_healthy(url: str = "http://127.0.0.1:7777/health") -> bool:
    try:
        with urlopen(url, timeout=0.5) as response:
            return response.status == 200
    except Exception:
        return False


def remove_legacy_launchagent_after_health(paths: RuntimePaths, *, home: Path | None = None, healthy: Callable[[], bool] = daemon_healthy, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> bool:
    if not healthy():
        return False
    user_home = home or Path.home()
    legacy = user_home / "Library/LaunchAgents" / f"{LEGACY_LAUNCHAGENT_LABEL}.plist"
    if not legacy.exists():
        return False
    run(["launchctl", "bootout", f"gui/{os.getuid()}/{LEGACY_LAUNCHAGENT_LABEL}"], capture_output=True)
    legacy.unlink()
    return True


def apply_privacy_preset(name: str, config_path: Path) -> dict[str, object]:
    if name not in PRESETS:
        raise ValueError(f"unknown privacy preset: {name}")
    current: dict[str, object] = {}
    if config_path.exists():
        try:
            value = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                current = value
        except Exception:
            current = {}
    current.update(PRESETS[name])
    current.update({"configured": True, "privacyPreset": name})
    atomic_write_json(config_path, current)
    return current


def import_legacy_config(legacy_path: Path, config_path: Path, preset: str) -> dict[str, object]:
    selected = dict(PRESETS[preset])
    legacy = _read_json(legacy_path)
    imported: dict[str, object] = {}
    if isinstance(legacy, dict):
        for key in ("voice", "ttsSpeed", "ttsInstruct", "minChars", "supertonicPort", "voiceMode", "expressionLevel", "stt"):
            if key in legacy:
                imported[key] = legacy[key]
        if legacy.get("autoSpeak") is False:
            selected["autoSpeak"] = False
        if legacy.get("usageTracking") is False:
            selected["usageTracking"] = False
        assistant = legacy.get("assistantTts")
        if isinstance(assistant, dict) and assistant.get("enabled") is False:
            selected["externalLlm"] = False
            selected["assistantTts"] = {"enabled": False, "failureExplain": False, "riskExplain": False, "promptAdvice": False}
    imported.update(selected)
    imported.update({"configured": True, "privacyPreset": preset, "migration": {"importedLegacy": legacy_path.exists(), "source": str(legacy_path)}})
    atomic_write_json(config_path, imported)
    return imported


def collect_status(paths: RuntimePaths) -> dict[str, object]:
    config: dict[str, object] = {}
    if paths.config.exists():
        try:
            config = json.loads(paths.config.read_text(encoding="utf-8"))
        except Exception:
            pass
    claude_delivery = _read_json(paths.data_dir / "last_hook_delivery_claude.json")
    codex_delivery = _read_json(paths.data_dir / "last_hook_delivery_codex.json")
    return {
        "configured": bool(config.get("configured", False)),
        "privacy_preset": config.get("privacyPreset"),
        "auto_speak": bool(config.get("autoSpeak", False)),
        "external_llm": bool(config.get("externalLlm", False)),
        "usage_tracking": bool(config.get("usageTracking", False)),
        "runtime_release": str(paths.current.resolve()) if paths.current.exists() else None,
        "daemon_healthy": daemon_healthy(),
        "hook_delivery": {"claude": claude_delivery, "codex": codex_delivery},
        "codex_hook_guidance": None if codex_delivery else "Codex에서 /hooks를 열어 chorus 훅을 검토하고 신뢰하세요.",
        "queue_depth": _queue_depth(),
        "mute_state": _read_json(paths.data_dir / "mute.json"),
        "data_dir": str(paths.data_dir),
        "last_error": _read_json(paths.data_dir / "last_hook_delivery_error.json"),
    }


def _queue_depth() -> int:
    spool = Path("/tmp/tts-spool")
    if not spool.exists():
        return 0
    return len(list(spool.glob("*.wav"))) + len(list(spool.glob("*.mp3")))


def _read_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def set_mute(paths: RuntimePaths, scope: str) -> dict[str, object]:
    if scope not in {"global", "session", "30m", "off"}:
        raise ValueError("mute scope must be global, session, 30m, or off")
    state = {"scope": scope, "muted": scope != "off", "expiresAt": time.time() + 1800 if scope == "30m" else None}
    if scope == "session":
        state["sessionId"] = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CODEX_SESSION_ID")
    atomic_write_json(paths.data_dir / "mute.json", state)
    return state


def set_mode(paths: RuntimePaths, name: str) -> dict[str, object]:
    if name not in MODE_PRESETS:
        raise ValueError(f"unknown mode: {name}")
    current = _read_json(paths.config)
    config = dict(current) if isinstance(current, dict) else {}
    config.update(MODE_PRESETS[name])
    atomic_write_json(paths.config, config)
    return MODE_PRESETS[name]


def recent_digest(paths: RuntimePaths, count: int = 10) -> list[dict[str, object]]:
    events = []
    for path in sorted(paths.data_dir.glob("last_hook_delivery_*.json")):
        value = _read_json(path)
        if isinstance(value, dict):
            events.append(value)
    error = _read_json(paths.data_dir / "last_hook_delivery_error.json")
    if isinstance(error, dict):
        events.append(error)
    return sorted(events, key=lambda item: float(item.get("timestamp", 0)))[-count:]


def run_doctor(paths: RuntimePaths, *, health: Callable[[], bool] = daemon_healthy) -> list[Check]:
    checks = [
        Check("platform", platform.system() == "Darwin" and platform.machine() == "arm64", f"{platform.system()} {platform.machine()}", "Chorus TTS는 macOS Apple Silicon에서 실행하세요."),
        Check("runtime", paths.current.exists(), str(paths.current), "chorus-runtime install"),
        Check("config", paths.config.exists(), str(paths.config), "chorus-runtime setup local"),
        Check("daemon", health(), "http://127.0.0.1:7777/health", "chorus-runtime start"),
        Check("data_writable", os.access(paths.data_dir if paths.data_dir.exists() else paths.data_dir.parent, os.W_OK), str(paths.data_dir), f"mkdir -p {paths.data_dir}"),
    ]
    return [check if check.ok else check for check in checks]


def _runtime_source() -> Path:
    configured = os.environ.get("CHORUS_RUNTIME_SOURCE")
    if configured:
        return Path(configured)
    candidate = Path(__file__).resolve().parents[1]
    return candidate


def _print_status(value: Mapping[str, object], as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, ensure_ascii=False, indent=2, default=str))
        return
    for key, item in value.items():
        print(f"{key}: {item}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="chorus-runtime")
    parser.add_argument("command", choices=["install", "setup", "status", "doctor", "start", "stop", "restart", "mute", "listen", "mode", "digest", "uninstall"])
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--purge", action="store_true")
    args = parser.parse_args(argv)
    paths = RuntimePaths.from_environment()
    if args.command == "install":
        version = args.argument or os.environ.get("CHORUS_VERSION", "dev")
        result = install_release(_runtime_source(), version, paths)
        ensure_runtime_environment(paths, result.release)
        if platform.system() == "Darwin":
            install_launchagent(paths)
            for _ in range(40):
                if daemon_healthy():
                    remove_legacy_launchagent_after_health(paths)
                    break
                time.sleep(0.25)
        print(result.release)
    elif args.command == "setup":
        preset = args.argument or "local"
        apply_privacy_preset(preset, paths.config)
        _print_status(collect_status(paths), args.json)
    elif args.command == "status":
        _print_status(collect_status(paths), args.json)
    elif args.command == "doctor":
        checks = run_doctor(paths)
        _print_status({check.name: asdict(check) for check in checks}, args.json)
        return 0 if all(check.ok for check in checks) else 1
    elif args.command == "mute":
        _print_status(set_mute(paths, args.argument or "global"), args.json)
    elif args.command == "mode":
        _print_status(set_mode(paths, args.argument or "normal"), args.json)
    elif args.command == "digest":
        count = int(args.argument or "10")
        print(json.dumps(recent_digest(paths, count), ensure_ascii=False, indent=2))
    elif args.command == "listen":
        try:
            request = __import__("urllib.request", fromlist=["Request"]).Request("http://127.0.0.1:7777/stt/toggle", data=b"", method="POST")
            with urlopen(request, timeout=1) as response:
                print(response.read().decode("utf-8"))
        except Exception as error:
            print(json.dumps({"status": "disabled", "detail": str(error), "recovery": "chorus-runtime start"}, ensure_ascii=False))
            return 1
    elif args.command == "uninstall":
        uninstall_runtime(paths, purge=args.purge)
    else:
        service_action(args.command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
