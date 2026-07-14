from __future__ import annotations

import asyncio
import time
from typing import Mapping

from .config import load_config
from .event.hook_event import adapt_hook_payload
from .hook_dispatch import dispatch_hook_event
from .runtime_paths import RuntimePaths, atomic_write_json


async def ingest_hook_event(
    source: str,
    event_name: str,
    payload: Mapping[str, object],
    *,
    paths: RuntimePaths | None = None,
) -> dict[str, bool]:
    runtime_paths = paths or RuntimePaths.from_environment()
    config = load_config(runtime_paths.config)
    if not config.configured:
        return {"accepted": True, "active": False}
    event = adapt_hook_payload(payload, source=source, event_name=event_name)
    asyncio.create_task(dispatch_hook_event(event, config))
    atomic_write_json(
        runtime_paths.data_dir / f"last_hook_delivery_{event.source}.json",
        {"source": event.source, "event_name": event.event_name, "session_id": event.session_id, "timestamp": time.time()},
    )
    return {"accepted": True, "active": True}
