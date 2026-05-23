#!/usr/bin/env bash
# Supertonic TTS 서버 시작 스크립트 (포트 7788)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BIN="$SCRIPT_DIR/../tts-venv/bin"
PID_FILE="$SCRIPT_DIR/../.supertonic.pid"
LOG_FILE="/tmp/supertonic.log"
PORT=7788

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[Supertonic] 이미 실행 중 (PID $(cat "$PID_FILE"))"
    exit 0
fi

if ! [ -f "$VENV_BIN/supertonic" ]; then
    echo "[Supertonic] supertonic 미설치. setup-tts.sh를 먼저 실행하세요." >&2
    exit 1
fi

nohup "$VENV_BIN/supertonic" serve --host 127.0.0.1 --port "$PORT" \
    > "$LOG_FILE" 2>&1 &
BGPID=$!
echo "$BGPID" > "$PID_FILE"
sleep 1
if ! kill -0 "$BGPID" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "[Supertonic] 서버 시작 실패. 로그를 확인하세요: $LOG_FILE" >&2
    exit 1
fi
echo "[Supertonic] 서버 시작 (PID $BGPID, 포트 $PORT, 로그 $LOG_FILE)"
