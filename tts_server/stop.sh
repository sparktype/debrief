#!/usr/bin/env bash
# TTS 상주 서버 종료 스크립트

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PID_FILE="${PROJECT_DIR}/.tts_server.pid"
PORT=7777

kill_pid() {
    local pid="$1"
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}"
        echo "[TTS] PID ${pid} 종료 완료"
    else
        echo "[TTS] PID ${pid} 는 이미 종료되었습니다"
    fi
}

if [[ -f "${PID_FILE}" ]]; then
    PID=$(cat "${PID_FILE}")
    kill_pid "${PID}"
    rm -f "${PID_FILE}"
else
    echo "[TTS] PID 파일 없음 — 포트 ${PORT} 프로세스 탐색..."
    PIDS=$(lsof -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)
    if [[ -z "${PIDS}" ]]; then
        echo "[TTS] 실행 중인 서버 없음"
        exit 0
    fi
    for pid in ${PIDS}; do
        kill_pid "${pid}"
    done
fi
