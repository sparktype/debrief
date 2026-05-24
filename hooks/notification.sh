#!/usr/bin/env bash
# Notification hook — Claude 알림 메시지를 voice로 낭독
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
echo "$(date '+%H:%M:%S') [notification] $PAYLOAD" >> /tmp/voice-notification-debug.log
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice notification >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
