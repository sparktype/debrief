#!/usr/bin/env bash
# Claude Code SessionStart hook — 세션 시작 시 스킬 추천
cat > /dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../.venv/bin/python"
nohup "$VENV_PY" -m hook_voice hook-suggest > /dev/null 2>&1 &
disown $!; exit 0
