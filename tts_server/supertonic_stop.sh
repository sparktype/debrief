#!/usr/bin/env bash
# Supertonic TTS 서버 종료 스크립트
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/../.supertonic.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    kill "$PID" 2>/dev/null && echo "[Supertonic] 서버 종료 (PID $PID)" || true
    rm -f "$PID_FILE"
else
    echo "[Supertonic] 실행 중인 서버 없음"
fi
