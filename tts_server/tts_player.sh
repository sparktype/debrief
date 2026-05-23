#!/usr/bin/env bash
# TTS 스풀 소비자 데몬 — /tmp/tts-spool/ 에서 epoch_ms 순서대로 재생
set -euo pipefail

SPOOL=/tmp/tts-spool
PID_FILE=/tmp/tts-player.pid
MAX_SLEEP=2.0
MIN_SLEEP=0.3

mkdir -p "$SPOOL"
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# 자신($$)을 제외한 동일 스크립트 실행 중이면 즉시 종료
EXISTING=$(pgrep -f "tts_player.sh" 2>/dev/null | grep -v "^$$\$" || true)
if [[ -n "$EXISTING" ]]; then
  echo "[TTS Player] 이미 실행 중 (PID $EXISTING) — 중복 실행 방지"
  exit 0
fi

echo "[TTS Player] 시작 (PID $$, 스풀: $SPOOL)"

MAX_AGE_SECS=300   # 5분
MAX_FILES=10

_cleanup_stale() {
  # 5분 초과 오디오 파일 삭제
  find "$SPOOL" \( -name "*.wav" -o -name "*.mp3" \) -mmin +$(( MAX_AGE_SECS / 60 )) -delete 2>/dev/null || true
  # meta 파일도 정리 (대응 오디오 없는 고아)
  find "$SPOOL" -name "*.meta" -mmin +$(( MAX_AGE_SECS / 60 )) -delete 2>/dev/null || true

  # 파일 수 제한
  local files=()
  mapfile -t files < <(find "$SPOOL" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | sort)
  local count=${#files[@]}
  if (( count > MAX_FILES )); then
    local excess=$(( count - MAX_FILES ))
    for f in "${files[@]:0:$excess}"; do
      rm -f "$f" "${f%.*}.meta"
    done
  fi
}

# 데몬 시작 시 한 번 실행
_cleanup_stale
echo "[TTS Player] 스풀 정리 완료"

idle_count=0

while true; do
  # epoch_ms 기준 오름차순 — 먼저 도착한 파일 먼저 재생
  audio=$(find "$SPOOL" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | sort | head -1 || true)
  if [[ -n "$audio" && -f "$audio" ]]; then
    idle_count=0  # 파일 발견 시 idle 카운터 초기화
    base="${audio%.*}"
    meta="${base}.meta"
    speed=$(cat "$meta" 2>/dev/null || echo "1.2")
    rm -f "$meta"
    afplay -r "$speed" "$audio" 2>/dev/null || true
    rm -f "$audio"
  else
    # 연속 idle 횟수에 따라 sleep 지수 증가 (최대 MAX_SLEEP)
    idle_count=$(( idle_count + 1 ))
    sleep_time=$(awk "BEGIN { s=$MIN_SLEEP * (1.5^$idle_count); print (s > $MAX_SLEEP ? $MAX_SLEEP : s) }")
    sleep "$sleep_time"
  fi
done
