#!/usr/bin/env bash
# TTS 스풀 소비자 데몬 — /tmp/tts-spool/ 에서 epoch_ms 순서대로 재생
set -euo pipefail

SPOOL=/tmp/tts-spool
PID_FILE=/tmp/tts-player.pid

mkdir -p "$SPOOL"
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

echo "[TTS Player] 시작 (PID $$, 스풀: $SPOOL)"

while true; do
  # epoch_ms 기준 오름차순 — 먼저 도착한 파일 먼저 재생
  audio=$(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort | head -1 || true)
  if [[ -n "$audio" && -f "$audio" ]]; then
    base="${audio%.*}"
    meta="${base}.meta"
    speed=$(cat "$meta" 2>/dev/null || echo "1.2")
    rm -f "$meta"
    afplay -r "$speed" "$audio" 2>/dev/null || true
    rm -f "$audio"
  else
    sleep 0.3
  fi
done
