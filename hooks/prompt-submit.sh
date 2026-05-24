#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest > /dev/null 2>&1 &
disown $!; exit 0
