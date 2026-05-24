#!/usr/bin/env bash
# PostToolUse Bash hook — 빌드·테스트 결과를 voice로 알림
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" post-tool-bash > /dev/null 2>&1 &
disown $!; exit 0
