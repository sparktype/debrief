import json
from pathlib import Path


def test_shared_hooks_cover_exact_common_contract():
    hooks = json.loads(Path("plugins/chorus/hooks/hooks.json").read_text())["hooks"]
    assert set(hooks) == {"Stop", "SubagentStop", "PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart"}
    commands = [hook["hooks"][0]["command"] for entries in hooks.values() for hook in entries]
    assert all("chorus-hook" in command for command in commands)
    assert all("/Users/" not in command for command in commands)


def test_claude_only_hooks_are_not_claimed_as_shared():
    hooks = json.loads(Path("plugins/chorus/hooks/claude-hooks.json").read_text())["hooks"]
    assert set(hooks) == {"Notification"}
