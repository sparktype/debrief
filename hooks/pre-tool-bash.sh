#!/usr/bin/env bash
# PreToolUse Bash hook — 빌드·테스트 착수 및 파괴적 명령 경고를 voice로 알림
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" pre-tool-bash > /dev/null 2>&1 &
disown $!; exit 0
