#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
AGENT_TYPE=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('agent_type',''))" 2>/dev/null || echo "")
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice subagent-stop "$AGENT_TYPE" >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
