#!/usr/bin/env bash
# summary-voice-mcp 실행·관리 스크립트
# 사용법: ./server.sh [start|stop|restart|status|logs [줄수]|install|uninstall]
set -euo pipefail

# ── 경로 설정 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/.tts_server.log"
SETTINGS_JSON="$HOME/.claude/settings.json"
HOOK_CMD="$SCRIPT_DIR/hooks/stop.sh"

# ── launchd 서비스 설정 (macOS) ────────────────────────────
LAUNCHD_PLIST_DIR="$HOME/Library/LaunchAgents"
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/com.voice-persona.tts-server.plist"
LAUNCHD_LABEL="com.voice-persona.tts-server"

# ── TTS 서버 설정 ──────────────────────────────────────────
TTS_PORT=7777
SUPERTONIC_PORT=7788
PLAYER_PID_FILE=/tmp/tts-player.pid
PLAYER_SPOOL=/tmp/tts-spool

# ── 환경변수 ───────────────────────────────────────────────
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"

# HMG Hub 공용 엔드포인트 (LLM 요약)
export HUB_BASE_URL="${HUB_BASE_URL:-https://internal-apigw-kr.hmg-corp.io/hchat-in/api/v3}"
export LLM_MODEL="${LLM_MODEL:-gpt-5.4}"

# HUB_API_KEY 미설정 시 로컬 rc 파일에서 읽어옴
if [[ -z "${HUB_API_KEY:-}" ]]; then
  for _rc in "$HOME/.zshenv.local" "$HOME/.zshrc.local" "$HOME/.zshenv"; do
    if [[ -f "$_rc" ]]; then
      # shellcheck disable=SC1090
      set -a; source "$_rc" 2>/dev/null || true; set +a
      [[ -n "${HUB_API_KEY:-}" ]] && break
    fi
  done
fi

# ── 헬퍼 함수 ─────────────────────────────────────────────

_tts_running() {
  lsof -iTCP:${TTS_PORT} -sTCP:LISTEN -t >/dev/null 2>&1
}

_supertonic_running() {
  lsof -iTCP:${SUPERTONIC_PORT} -sTCP:LISTEN -t >/dev/null 2>&1
}

_supervisor_running() {
  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}

_check_health() {
  local port="${1:-$TTS_PORT}"
  local path="${2:-/health}"
  curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 1 "http://127.0.0.1:${port}${path}" 2>/dev/null
}

_is_launchd_managed() {
  [[ -f "$LAUNCHD_PLIST" ]] && launchctl list "$LAUNCHD_LABEL" &>/dev/null
}

_check_deps() {
  if [[ ! -d "$SCRIPT_DIR/tts-venv" ]]; then
    echo "경고: tts-venv 없음 — setup-tts.sh를 먼저 실행하세요." >&2
  fi
  if [[ -z "${HUB_API_KEY:-}" ]]; then
    echo "경고: HUB_API_KEY 미설정 — LLM 요약이 폴백으로 동작합니다." >&2
  fi
}

# ── 수동 관리 명령 ─────────────────────────────────────────

_kill_orphan_players() {
  # 구버전 tts_player.sh 및 launchd 외부에서 실행 중인 고아 supervisor.py 종료
  local launchd_pid
  launchd_pid=$(launchctl list "$LAUNCHD_LABEL" 2>/dev/null | awk '/"PID"/{gsub(/[^0-9]/,"",$3); print $3}')

  local pids
  pids=$(pgrep -f "tts_player.sh" 2>/dev/null)
  for pid in $pids; do
    [[ "$pid" == "$launchd_pid" ]] && continue
    kill "$pid" 2>/dev/null && echo "  고아 tts_player.sh 종료: PID $pid"
  done

  pids=$(pgrep -f "tts_server/supervisor.py" 2>/dev/null)
  for pid in $pids; do
    [[ "$pid" == "$launchd_pid" ]] && continue
    kill "$pid" 2>/dev/null && echo "  고아 supervisor.py 종료: PID $pid"
  done
}

do_start() {
  _check_deps
  _kill_orphan_players

  if _is_launchd_managed; then
    echo "launchd 서비스가 supervisor를 관리 중입니다."
    echo "  일시 중지: launchctl stop  $LAUNCHD_LABEL"
    echo "  재시작:    launchctl start $LAUNCHD_LABEL"
    echo "  완전 제거: $(basename "$0") uninstall"
    return 0
  fi

  if _supervisor_running; then
    local pid
    pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
    echo "이미 실행 중 (supervisor PID: $pid)"
    return 0
  fi

  echo "Supervisor 시작 중..."
  nohup "$SCRIPT_DIR/tts-venv/bin/python" \
      "$SCRIPT_DIR/tts_server/supervisor.py" \
      >> "$LOG_FILE" 2>&1 &
  disown $!

  local i=0
  while (( i < 10 )); do
    if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
      echo "✓ TTS 서버 기동 완료 (HTTP 200)"
      return 0
    fi
    sleep 1
    i=$(( i + 1 ))
  done
  echo "✓ Supervisor 기동됨 — 모델 로딩 중, 잠시 후 응답 예정"
}

do_stop() {
  if _is_launchd_managed; then
    echo "launchd 관리 서버 종료 중 (launchctl stop)..."
    launchctl stop "$LAUNCHD_LABEL"
    local i=0
    while (( i < 8 )); do
      _supervisor_running || break
      sleep 1
      i=$(( i + 1 ))
    done
    return 0
  fi

  if ! _supervisor_running; then
    echo "Supervisor가 실행 중이지 않습니다."
    return 0
  fi

  local pid
  pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
  echo "Supervisor 종료 중 (PID $pid)..."
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while (( i < 8 )); do
    _supervisor_running || break
    sleep 1
    i=$(( i + 1 ))
  done
  rm -f "$SCRIPT_DIR/.tts_server.pid"
  echo "종료 완료"
}

do_restart() {
  do_stop
  do_start
}

do_status() {
  echo "● voice-persona 상태"

  # Supervisor 확인
  if _supervisor_running; then
    local pid
    pid=$(cat "$SCRIPT_DIR/.tts_server.pid" 2>/dev/null)
    echo "  Supervisor: ✓ 실행 중 (PID: $pid)"
  else
    echo "  Supervisor: ✗ 중지됨"
  fi

  # TTS 서버 확인
  if _tts_running; then
    local pid
    pid=$(lsof -iTCP:${TTS_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
    echo "  TTS 서버:  ✓ 실행 중 (PID: $pid, 포트 ${TTS_PORT})"
    if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
      echo "  HTTP:      ✓ /health 응답 정상"
    else
      echo "  HTTP:      ✗ /health 미응답 (모델 로딩 중이거나 오류)"
    fi
  else
    echo "  TTS 서버:  ✗ 중지됨"
  fi

  # Supertonic 서버 확인
  if _supertonic_running; then
    local st_pid
    st_pid=$(lsof -iTCP:${SUPERTONIC_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
    echo "  Supertonic: ✓ 실행 중 (PID: $st_pid, 포트 ${SUPERTONIC_PORT})"
    if [[ "$(_check_health "$SUPERTONIC_PORT" "/v1/health")" == "200" ]]; then
      echo "  ST HTTP:    ✓ /v1/health 응답 정상"
    else
      echo "  ST HTTP:    △ /v1/health 미응답 (모델 로딩 중이거나 오류)"
    fi
  else
    echo "  Supertonic: ✗ 중지됨"
  fi

  # Stop hook 등록 확인
  local hook_registered=false
  if [[ -f "$SETTINGS_JSON" ]]; then
    hook_registered=$(python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS_JSON'))
    stops = d.get('hooks', {}).get('Stop', [])
    print('true' if any('$SCRIPT_DIR' in str(h) for h in stops) else 'false')
except Exception:
    print('false')
" 2>/dev/null)
  fi
  if [[ "$hook_registered" == "true" ]]; then
    echo "  Stop hook: ✓ 등록됨 ($SETTINGS_JSON)"
  else
    echo "  Stop hook: ✗ 미등록 — $(basename "$0") install 로 등록"
  fi

  # launchd 서비스 상태
  if [[ -f "$LAUNCHD_PLIST" ]]; then
    echo ""
    local launchd_row
    launchd_row=$(launchctl list 2>/dev/null | grep "$LAUNCHD_LABEL" || true)
    if [[ -n "$launchd_row" ]]; then
      local launchd_pid launchd_status
      launchd_pid=$(echo "$launchd_row" | awk '{print $1}')
      launchd_status=$(echo "$launchd_row" | awk '{print $2}')
      echo "  launchd:   ✓ 등록됨 (자동 재시작 활성화)"
      if [[ "$launchd_pid" != "-" ]]; then
        echo "  launchd PID: $launchd_pid"
      else
        echo "  launchd PID: 중지됨 (종료 코드 $launchd_status)"
      fi
    else
      echo "  launchd:   ○ plist 존재, 미로드 상태"
    fi
  fi

  echo ""
  echo "  모델:      ${LLM_MODEL} (${HUB_BASE_URL})"
  echo "  로그:      $LOG_FILE"
}

do_logs() {
  local lines="${2:-50}"
  if [[ -f "$LOG_FILE" ]]; then
    echo "=== 최근 ${lines}줄 ($LOG_FILE) ==="
    tail -n "$lines" "$LOG_FILE"
  else
    echo "로그 파일 없음: $LOG_FILE"
    return 1
  fi
}

# ── launchd 서비스 관리 ────────────────────────────────────

do_install() {
  _check_deps

  # 1. Stop hook 등록
  echo "Stop hook 등록 중..."
  if [[ ! -f "$SETTINGS_JSON" ]]; then
    echo '{}' > "$SETTINGS_JSON"
  fi
  python3 - "$SETTINGS_JSON" "$HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
stop_list = hooks.setdefault("Stop", [])
if any(hook_cmd in str(h) for h in stop_list):
    print("  Stop hook 이미 등록됨 — 스킵")
else:
    stop_list.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 15}]
    })
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ Stop hook 등록 완료")
PYEOF

  # 2. SubagentStop hook 등록
  echo "SubagentStop hook 등록 중..."
  SUBAGENT_HOOK_CMD="$SCRIPT_DIR/hooks/subagent-stop.sh"
  python3 - "$SETTINGS_JSON" "$SUBAGENT_HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
stop_list = hooks.setdefault("SubagentStop", [])
if any(hook_cmd in str(h) for h in stop_list):
    print("  SubagentStop hook 이미 등록됨 — 스킵")
else:
    stop_list.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 15}]
    })
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ SubagentStop hook 등록 완료")
PYEOF

  # 3. TTS LaunchAgent 등록 (수동 실행 supervisor 종료 후)
  if _supervisor_running && ! _is_launchd_managed; then
    echo "수동 실행 Supervisor 종료 중..."
    do_stop
  fi

  echo "TTS LaunchAgent 등록 중..."
  mkdir -p "$LAUNCHD_PLIST_DIR"

  if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
    echo "  기존 LaunchAgent 언로드 중..."
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  fi

  cat > "$LAUNCHD_PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/tts-venv/bin/python</string>
    <string>${SCRIPT_DIR}/tts_server/supervisor.py</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <!-- 비정상 종료(크래시)만 재시작 — launchctl stop 후에는 재시작 안 함 -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <!-- 크래시 루프 방지: 재시작 최소 간격 10초 -->
  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${SCRIPT_DIR}/tts-venv/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HUB_BASE_URL</key>
    <string>${HUB_BASE_URL:-}</string>
    <key>HUB_API_KEY</key>
    <string>${HUB_API_KEY:-}</string>
    <key>HUB_PROJECT_ID</key>
    <string>${HUB_PROJECT_ID:-}</string>
    <key>VOICE_PERSONA_VENV_PYTHON</key>
    <string>${VOICE_PERSONA_VENV_PYTHON:-}</string>
  </dict>
</dict>
</plist>
PLIST_EOF

  launchctl load "$LAUNCHD_PLIST"
  echo "  ✓ LaunchAgent 등록 완료"

  # 기동 대기 (최대 10초)
  local i=0
  while (( i < 10 )); do
    if [[ "$(_check_health "$TTS_PORT")" == "200" ]]; then
      break
    fi
    sleep 1
    i=$(( i + 1 ))
  done

  echo ""
  echo "✓ voice-persona 설치 완료"
  echo ""
  echo "  Stop hook: Claude 응답 완료 시 자동 TTS 실행"
  echo "  TTS 서버:  로그인 시 자동 시작 + 크래시 후 자동 재시작"
  echo "  로그:      $LOG_FILE"
  echo ""
  echo "제어 명령:"
  echo "  일시 중지: launchctl stop  $LAUNCHD_LABEL"
  echo "  재시작:    launchctl start $LAUNCHD_LABEL"
  echo "  완전 제거: $(basename "$0") uninstall"
}

do_uninstall() {
  # Stop hook 제거
  echo "Stop hook 제거 중..."
  if [[ -f "$SETTINGS_JSON" ]]; then
    python3 - "$SETTINGS_JSON" "$HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
stop = d.get("hooks", {}).get("Stop", [])
before = len(stop)
d["hooks"]["Stop"] = [h for h in stop if hook_cmd not in str(h)]
if len(d["hooks"]["Stop"]) < before:
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ Stop hook 제거 완료")
else:
    print("  Stop hook이 등록되지 않았습니다.")
PYEOF
  fi

  # SubagentStop hook 제거
  echo "SubagentStop hook 제거 중..."
  SUBAGENT_HOOK_CMD="$SCRIPT_DIR/hooks/subagent-stop.sh"
  if [[ -f "$SETTINGS_JSON" ]]; then
    python3 - "$SETTINGS_JSON" "$SUBAGENT_HOOK_CMD" << 'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
sub = d.get("hooks", {}).get("SubagentStop", [])
before = len(sub)
d["hooks"]["SubagentStop"] = [h for h in sub if hook_cmd not in str(h)]
if len(d["hooks"]["SubagentStop"]) < before:
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("  ✓ SubagentStop hook 제거 완료")
else:
    print("  SubagentStop hook이 등록되지 않았습니다.")
PYEOF
  fi

  # Supervisor 종료 + LaunchAgent 제거
  if _supervisor_running; then
    echo "Supervisor 종료 중..."
    do_stop
  fi
  if [[ -f "$LAUNCHD_PLIST" ]]; then
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST"
    echo "  ✓ LaunchAgent 제거 완료"
  fi

  echo ""
  echo "✓ voice-persona 제거 완료"
  echo "  수동 실행: $(basename "$0") start"
}

# ── 메인 ──────────────────────────────────────────────────
CMD="${1:-status}"
case "$CMD" in
  start)     do_start ;;
  stop)      do_stop ;;
  restart)   do_restart ;;
  status)    do_status ;;
  logs)      do_logs "$@" ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  *)
    echo "사용법: $(basename "$0") [start|stop|restart|status|logs [줄수]|install|uninstall]"
    exit 1
    ;;
esac
