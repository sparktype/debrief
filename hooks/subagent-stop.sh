#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice subagent-stop >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
