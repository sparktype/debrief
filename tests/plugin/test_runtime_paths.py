import json

from hook_voice.runtime_paths import RuntimePaths, atomic_write_json


def test_runtime_paths_are_stable_outside_plugin_cache(tmp_path):
    paths = RuntimePaths.from_environment(
        {"HOME": str(tmp_path), "PLUGIN_ROOT": "/cache/v2"}
    )
    assert paths.data_dir == tmp_path / ".local/share/chorus"
    assert paths.current == paths.data_dir / "runtime/current"


def test_atomic_write_json_replaces_content(tmp_path):
    path = tmp_path / "state.json"
    atomic_write_json(path, {"version": 1})
    atomic_write_json(path, {"version": 2})
    assert json.loads(path.read_text()) == {"version": 2}
    assert list(tmp_path.iterdir()) == [path]
