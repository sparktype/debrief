#!/bin/bash
# PostToolUse Bash hook — 빌드·테스트 결과를 voice로 알림
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice post-tool-bash >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
