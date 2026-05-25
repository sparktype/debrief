#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice hook-suggest >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
