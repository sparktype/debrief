#!/bin/zsh -l
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"
AGENT_TYPE=$(echo "$PAYLOAD" | "$VENV_PY" -c "import sys,json;d=json.load(sys.stdin);print(d.get('agent_type',''))" 2>/dev/null || echo "")
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice subagent-stop "$AGENT_TYPE" >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
