from pathlib import Path


def test_legacy_management_scripts_delegate_to_runtime():
    for name in ("setup-tts.sh", "server.sh", "install.sh", "uninstall.sh"):
        body = Path(name).read_text()
        assert "deprecated" in body.lower() or "마이그레이션" in body
        assert "chorus-runtime" in body


def test_no_committed_hook_contains_developer_home_or_nohup():
    for path in Path("hooks").glob("*.sh"):
        body = path.read_text()
        assert "/Users/" not in body
        assert "nohup" not in body


def test_legacy_hook_wrappers_use_fail_open_runner():
    for name in ("stop.sh", "subagent-stop.sh", "pre-tool-bash.sh", "post-tool-bash.sh", "prompt-submit.sh", "session-start.sh", "notification.sh"):
        body = (Path("hooks") / name).read_text()
        assert "chorus-hook" in body
        assert "exit 0" in body
