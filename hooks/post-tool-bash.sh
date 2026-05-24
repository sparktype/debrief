#!/usr/bin/env bash
# PostToolUse Bash hook — 빌드·테스트 결과를 voice로 알림
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice post-tool-bash > /dev/null 2>&1 &
disown $!; exit 0
