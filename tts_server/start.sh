#!/usr/bin/env bash
# TTS 상주 서버 시작 스크립트 — 이미 실행 중이면 스킵, 아니면 백그라운드로 기동

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_DIR}/tts-venv"
PID_FILE="${PROJECT_DIR}/.tts_server.pid"
PORT=7777

# venv 존재 여부 확인
if [[ ! -d "${VENV_DIR}" ]]; then
    echo "[TTS] 오류: tts-venv 가 없습니다 → ${VENV_DIR}" >&2
    exit 1
fi

# 이미 포트가 열려 있으면 실행 중으로 간주
if lsof -iTCP:${PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[TTS] 이미 실행 중 (포트 ${PORT})"
    exit 0
fi

LOG_FILE="${PROJECT_DIR}/.tts_server.log"

echo "[TTS] 서버 시작 중 (포트 ${PORT})..."
cd "${PROJECT_DIR}"
nohup "${VENV_DIR}/bin/uvicorn" \
    tts_server.server:app \
    --host 127.0.0.1 \
    --port ${PORT} \
    >> "${LOG_FILE}" 2>&1 &
SERVER_PID=$!
disown "${SERVER_PID}"

echo "${SERVER_PID}" > "${PID_FILE}"
echo "[TTS] 서버 PID=${SERVER_PID}, 로그=${LOG_FILE}"
