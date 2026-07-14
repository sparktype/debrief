from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


@dataclass(frozen=True)
class RuntimePaths:
    data_dir: Path
    runtime_dir: Path
    releases: Path
    current: Path
    config: Path
    state: Path
    logs: Path

    @classmethod
    def from_environment(cls, env: Mapping[str, str] | None = None) -> "RuntimePaths":
        values = os.environ if env is None else env
        home = Path(values.get("HOME", str(Path.home()))).expanduser()
        root = Path(values.get("CHORUS_DATA_DIR", home / ".local/share/chorus")).expanduser()
        runtime = root / "runtime"
        return cls(
            data_dir=root,
            runtime_dir=runtime,
            releases=runtime / "releases",
            current=runtime / "current",
            config=root / "config.json",
            state=root / "state.json",
            logs=root / "logs",
        )


def atomic_write_json(path: Path, value: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
