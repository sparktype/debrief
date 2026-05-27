#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice hook >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
