#!/bin/bash
# Claude Code PreToolUse hook — Monitor 도구 호출 시 리뷰어 플래그 설정
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice pre-tool-monitor >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
