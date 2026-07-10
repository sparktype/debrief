#!/bin/zsh -l
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice hook >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
