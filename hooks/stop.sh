#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" hook > /dev/null 2>&1 &
disown $!; exit 0
