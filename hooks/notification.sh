#!/bin/zsh -l
# Notification hook — Claude 알림 메시지를 voice로 낭독
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$(date '+%H:%M:%S') [notification] $PAYLOAD" >> /tmp/voice-notification-debug.log
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice notification >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
