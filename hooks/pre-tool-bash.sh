#!/bin/zsh -l
# PreToolUse Bash hook — 빌드·테스트 착수 및 파괴적 명령 경고를 voice로 알림
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice pre-tool-bash >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
