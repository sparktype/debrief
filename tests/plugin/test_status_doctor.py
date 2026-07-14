from hook_voice.runtime_manager import collect_status, run_doctor
from hook_voice.runtime_paths import RuntimePaths, atomic_write_json


def test_status_shows_privacy_hook_guidance_and_last_error(tmp_path, monkeypatch):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    atomic_write_json(paths.config, {"configured": True, "privacyPreset": "local", "autoSpeak": True})
    atomic_write_json(paths.data_dir / "last_hook_delivery_error.json", {"error": "offline"})
    monkeypatch.setattr("hook_voice.runtime_manager.daemon_healthy", lambda: False)
    status = collect_status(paths)
    assert status["privacy_preset"] == "local"
    assert status["last_error"] == {"error": "offline"}
    assert "/hooks" in status["codex_hook_guidance"]


def test_doctor_reports_exact_recovery_for_stopped_daemon(tmp_path):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path)})
    checks = run_doctor(paths, health=lambda: False)
    daemon = next(check for check in checks if check.name == "daemon")
    assert daemon.ok is False
    assert daemon.recovery == "chorus-runtime start"
