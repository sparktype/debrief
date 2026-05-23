#!/usr/bin/env bash
# Supertonic TTS 서버 시작 스크립트 (포트 7788)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BIN="$SCRIPT_DIR/../tts-venv/bin"
LOG_FILE="/tmp/supertonic.log"
PORT=7788

if lsof -iTCP:${PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
    PID=$(lsof -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
    echo "[Supertonic] 이미 실행 중 (PID $PID)"
    exit 0
fi

if ! [ -f "$VENV_BIN/supertonic" ]; then
    echo "[Supertonic] supertonic 미설치. setup-tts.sh를 먼저 실행하세요." >&2
    exit 1
fi

# Supertonic은 모델을 HuggingFace에서 캐시하므로 첫 실행 시 다운로드 허용
nohup env HF_HUB_OFFLINE=0 "$VENV_BIN/supertonic" serve --host 127.0.0.1 --port "$PORT" \
    > "$LOG_FILE" 2>&1 &
BGPID=$!
echo "[Supertonic] 서버 시작 (PID $BGPID, 포트 $PORT, 로그 $LOG_FILE)"
echo "[Supertonic] /health 응답 대기 중 (최대 30초)..."
for i in $(seq 1 30); do
    code=$(curl -sf -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$PORT/v1/health" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        echo "[Supertonic] 서버 준비 완료 (${i}초)"
        exit 0
    fi
    sleep 1
done
echo "[Supertonic] 서버 시작 실패 (30초 타임아웃)" >&2
exit 1
