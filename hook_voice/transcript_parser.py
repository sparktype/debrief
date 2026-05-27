# hook_voice/transcript_parser.py
# JSONL 트랜스크립트 파싱 및 이벤트 추출
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Literal


@dataclass
class TranscriptEvent:
    role: Literal["user", "assistant", "tool", "unknown"]
    text: str
    agent_type: str = ""


def _extract_text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return " ".join(parts).strip()
    return ""


def _extract_agent_type(content: object) -> str:
    if not isinstance(content, list):
        return ""
    for block in content:
        if (
            isinstance(block, dict)
            and block.get("type") == "tool_use"
            and block.get("name") == "Agent"
        ):
            raw = block.get("input", {})
            if isinstance(raw, dict) and isinstance(raw.get("subagent_type"), str):
                return raw["subagent_type"]
    return ""


def parse_jsonl_line(raw: str) -> TranscriptEvent | None:
    try:
        entry = json.loads(raw)
    except Exception:
        return None

    msg = entry.get("message", entry)
    role_raw = msg.get("role", entry.get("type", "unknown"))
    role = role_raw if role_raw in {"user", "assistant"} else "unknown"
    content = msg.get("content", entry.get("content", ""))
    text = _extract_text(content)
    agent_type = _extract_agent_type(content)

    if agent_type and role == "unknown":
        role = "tool"

    return TranscriptEvent(role=role, text=text, agent_type=agent_type)


def iter_transcript_events(path: Path) -> Iterator[TranscriptEvent]:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        event = parse_jsonl_line(line)
        if event is not None:
            yield event


def get_last_assistant_text(path: Path, min_length: int = 20) -> str:
    events = list(iter_transcript_events(path))
    for event in reversed(events):
        if event.role == "assistant" and len(event.text) >= min_length:
            return event.text
    return ""


def extract_last_agent_type(path: Path) -> str:
    events = list(iter_transcript_events(path))
    for event in reversed(events):
        if event.agent_type:
            return event.agent_type
    return ""


def get_recent_dialogue(
    scan_dir: Path,
    recursive: bool,
    max_files: int,
    max_lines_per_file: int,
) -> str:
    if not scan_dir.exists():
        return ""
    glob_fn = scan_dir.rglob if recursive else scan_dir.glob
    files = sorted(glob_fn("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:max_files]
    parts: list[str] = []
    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()[-max_lines_per_file:]
        for line in lines:
            event = parse_jsonl_line(line)
            if event is None or not event.text:
                continue
            if event.role == "user":
                parts.append(f"User: {event.text[:300]}")
            elif event.role == "assistant":
                parts.append(f"Assistant: {event.text[:300]}")
        parts.append("---")
    return "\n".join(parts)
