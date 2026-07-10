#!/bin/zsh -l
# Claude Code PreToolUse hook — Monitor 도구 호출 시 리뷰어 플래그 설정
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice pre-tool-monitor >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
