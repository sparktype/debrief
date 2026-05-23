#!/usr/bin/env bash
# Supertonic TTS 서버 종료 스크립트 — 포트 점유 기반
PORT=7788
PID=$(lsof -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null && echo "[Supertonic] 서버 종료 (PID $PID, 포트 $PORT)" || true
else
    echo "[Supertonic] 실행 중인 서버 없음 (포트 $PORT)"
fi
