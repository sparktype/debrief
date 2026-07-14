import json
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text())


def test_dual_manifests_name_and_version_the_same_plugin():
    claude = load("plugins/chorus/.claude-plugin/plugin.json")
    codex = load("plugins/chorus/.codex-plugin/plugin.json")
    assert claude["name"] == codex["name"] == "chorus"
    assert claude["version"] == codex["version"]


def test_marketplaces_disclose_platform_auth_and_privacy():
    for path in (".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"):
        plugin = load(path)["plugins"][0]
        text = json.dumps(plugin).lower()
        assert "macos apple silicon" in text
        assert "authentication" in plugin
        assert "privacy" in plugin
