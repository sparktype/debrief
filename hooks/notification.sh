#!/usr/bin/env bash
# Notification hook — Claude 알림 메시지를 voice로 낭독
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" notification > /dev/null 2>&1 &
disown $!; exit 0
