#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
nohup "$VENV_PY" -m hook_voice hook >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
