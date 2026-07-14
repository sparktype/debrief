from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
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
    result = subprocess.run(
        [sys.executable, "-m", "compileall", "-q", str(release / "hook_voice"), str(release / "tts_server")],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise ReleaseValidationError(result.stderr.strip() or "runtime compilation failed")


def install_release(source: Path, version: str, paths: RuntimePaths) -> InstallResult:
    paths.releases.mkdir(parents=True, exist_ok=True)
    previous = paths.current.resolve() if paths.current.exists() else None
    destination = paths.releases / version
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
    executable = python or Path(sys.executable)
    log = paths.logs / "server.log"
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LAUNCHAGENT_LABEL}</string>
<key>ProgramArguments</key><array><string>{executable}</string><string>-m</string><string>tts_server.supervisor</string></array>
<key>WorkingDirectory</key><string>{paths.current}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>{log}</string><key>StandardErrorPath</key><string>{log}</string>
<key>EnvironmentVariables</key><dict><key>CHORUS_DATA_DIR</key><string>{paths.data_dir}</string><key>PYTHONPATH</key><string>{paths.current}</string></dict>
</dict></plist>\n'''


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


def collect_status(paths: RuntimePaths) -> dict[str, object]:
    config: dict[str, object] = {}
    if paths.config.exists():
        try:
            config = json.loads(paths.config.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "configured": bool(config.get("configured", False)),
        "privacy_preset": config.get("privacyPreset"),
        "auto_speak": bool(config.get("autoSpeak", False)),
        "external_llm": bool(config.get("externalLlm", False)),
        "usage_tracking": bool(config.get("usageTracking", False)),
        "runtime_release": str(paths.current.resolve()) if paths.current.exists() else None,
        "daemon_healthy": daemon_healthy(),
        "data_dir": str(paths.data_dir),
        "last_error": _read_json(paths.data_dir / "last_hook_delivery_error.json"),
    }


def _read_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


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
    parser.add_argument("command", choices=["install", "setup", "status", "doctor", "start", "stop", "restart", "uninstall"])
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--purge", action="store_true")
    args = parser.parse_args(argv)
    paths = RuntimePaths.from_environment()
    if args.command == "install":
        version = args.argument or os.environ.get("CHORUS_VERSION", "dev")
        result = install_release(_runtime_source(), version, paths)
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
    elif args.command == "uninstall":
        if paths.runtime_dir.exists():
            shutil.rmtree(paths.runtime_dir)
        if args.purge and paths.data_dir.exists():
            shutil.rmtree(paths.data_dir)
    else:
        subprocess.run(["launchctl", "kickstart" if args.command != "stop" else "kill", f"gui/{os.getuid()}/{LAUNCHAGENT_LABEL}"], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
