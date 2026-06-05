#!/usr/bin/env bash
# TTS Supervisor 서비스 관리 — launchctl 래퍼
# 사용법: ./server.sh [start|stop|restart|status|logs [N]|install|uninstall|pause|resume|flush|skip]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/.tts_server.log"

LAUNCHD_PLIST_DIR="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="io.chorus.server"
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/$LAUNCHD_LABEL.plist"

TTS_PORT=7777
SUPERTONIC_PORT=7788
VENV_PY="$SCRIPT_DIR/.venv/bin/python"

# ── 환경변수 (plist 생성 시 삽입용) ──────────────────────────
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export HUB_BASE_URL="${HUB_BASE_URL:-https://internal-apigw-kr.hmg-corp.io/hchat-in/api/v3}"
export LLM_MODEL="${LLM_MODEL:-gemini-3.5-flash}"

if [[ -z "${AI_API_KEY:-}" && -z "${HUB_API_KEY:-}" ]]; then
  for _rc in "$HOME/.zshenv.local" "$HOME/.zshrc.local" "$HOME/.zshenv"; do
    if [[ -f "$_rc" ]]; then
      set -a; source "$_rc" 2>/dev/null || true; set +a
      [[ -n "${AI_API_KEY:-}" || -n "${HUB_API_KEY:-}" ]] && break
    fi
  done
fi

# ── 헬퍼 ──────────────────────────────────────────────────

_launchd_loaded() {
  launchctl list "$LAUNCHD_LABEL" &>/dev/null
}

_tts_running() {
  lsof -iTCP:${TTS_PORT} -sTCP:LISTEN -t >/dev/null 2>&1
}

_supertonic_running() {
  lsof -iTCP:${SUPERTONIC_PORT} -sTCP:LISTEN -t >/dev/null 2>&1
}

_check_health() {
  curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 1 "http://127.0.0.1:${1:-$TTS_PORT}${2:-/health}" 2>/dev/null
}

_require_plist() {
  if [[ ! -f "$LAUNCHD_PLIST" ]]; then
    echo "launchd 서비스가 등록되지 않았습니다. 먼저 ./server.sh install 을 실행하세요." >&2
    exit 1
  fi
}

_wait_for_stop() {
  local i=0
  while (( i < 8 )); do
    _tts_running || return 0
    sleep 1; i=$(( i + 1 ))
  done
}

# ── 명령 ──────────────────────────────────────────────────

do_start() {
  _require_plist
  if ! _launchd_loaded; then
    echo "LaunchAgent 로드 중..."
    launchctl load "$LAUNCHD_PLIST"
  fi
  echo "TTS 서버 시작 중..."
  launchctl start "$LAUNCHD_LABEL"
  local i=0
  while (( i < 10 )); do
    [[ "$(_check_health)" == "200" ]] && { echo "✓ 기동 완료"; return 0; }
    sleep 1; i=$(( i + 1 ))
  done
  echo "✓ 기동 요청됨 — 모델 로딩 중 (./server.sh logs 로 확인)"
}

do_stop() {
  _require_plist
  echo "TTS 서버 종료 중..."
  launchctl stop "$LAUNCHD_LABEL" 2>/dev/null || true
  _wait_for_stop
  echo "✓ 종료됨"
}

do_restart() {
  _require_plist
  echo "TTS 서버 재시작 중..."
  launchctl stop "$LAUNCHD_LABEL" 2>/dev/null || true
  _wait_for_stop
  launchctl start "$LAUNCHD_LABEL"
  local i=0
  while (( i < 10 )); do
    [[ "$(_check_health)" == "200" ]] && { echo "✓ 재시작 완료"; return 0; }
    sleep 1; i=$(( i + 1 ))
  done
  echo "✓ 재시작 요청됨 — 모델 로딩 중"
}

do_status() {
  echo "● voice-persona 상태"

  # TTS 서버
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

  # Supertonic
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

  # launchd
  echo ""
  if [[ -f "$LAUNCHD_PLIST" ]]; then
    local row
    row=$(launchctl list 2>/dev/null | grep "$LAUNCHD_LABEL" || true)
    if [[ -n "$row" ]]; then
      local lpid lcode
      lpid=$(echo "$row" | awk '{print $1}')
      lcode=$(echo "$row" | awk '{print $2}')
      echo "  launchd:   ✓ 로드됨 (자동 재시작 활성화)"
      if [[ "$lpid" != "-" ]]; then
        echo "  launchd PID: $lpid"
      else
        echo "  launchd PID: 중지됨 (종료 코드 $lcode)"
      fi
    else
      echo "  launchd:   ○ plist 존재, 미로드 상태"
    fi
  else
    echo "  launchd:   ✗ 미등록 — ./server.sh install 로 등록"
  fi

  # hook 등록 상태 (Claude Code 기준)
  local claude_settings="$HOME/.claude/settings.json"
  if [[ -f "$claude_settings" ]]; then
    local hook_ok
    hook_ok=$(python3 -c "
import json
d = json.load(open('$claude_settings'))
stops = d.get('hooks', {}).get('Stop', [])
print('true' if any('$SCRIPT_DIR' in str(h) for h in stops) else 'false')
" 2>/dev/null)
    if [[ "$hook_ok" == "true" ]]; then
      echo "  Stop hook: ✓ 등록됨 (Claude Code)"
    else
      echo "  Stop hook: ✗ 미등록 — ./install.sh claude 로 등록"
    fi
  fi

  # TTS 큐
  local queue_count=0
  [[ -d "/tmp/tts-spool" ]] && \
    queue_count=$(find /tmp/tts-spool -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | wc -l | tr -d ' ')

  local last_msg=""
  local last_msg_file=""
  if [[ -x "$VENV_PY" ]]; then
    last_msg_file=$("$VENV_PY" -c "from hook_voice.last_message import _get_last_msg_file; print(_get_last_msg_file())" 2>/dev/null || true)
  fi
  [[ -n "$last_msg_file" && -f "$last_msg_file" ]] && last_msg=$(head -c 60 "$last_msg_file" 2>/dev/null)

  echo ""
  echo "[TTS 큐]"
  echo "  대기: ${queue_count}개"
  [[ -n "$last_msg" ]] && echo "  마지막 발화: $last_msg"
  echo ""
  echo "  모델: ${LLM_MODEL} (${HUB_BASE_URL})"
  echo "  로그: $LOG_FILE"
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

# ── launchd 설치/제거 ──────────────────────────────────────

do_install() {
  if [[ ! -d "$SCRIPT_DIR/.venv" ]]; then
    echo "경고: .venv 없음 — setup-tts.sh를 먼저 실행하세요." >&2
  fi
  if [[ -z "${AI_API_KEY:-}" && -z "${HUB_API_KEY:-}" ]]; then
    echo "경고: AI_API_KEY 미설정 — LLM 요약이 폴백으로 동작합니다." >&2
  fi

  echo "TTS LaunchAgent 등록 중..."
  mkdir -p "$LAUNCHD_PLIST_DIR"

  if _launchd_loaded; then
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
    <string>${SCRIPT_DIR}/.venv/bin/python</string>
    <string>-m</string>
    <string>tts_server.supervisor</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>WorkingDirectory</key>
  <string>${SCRIPT_DIR}</string>

  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${SCRIPT_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HUB_BASE_URL</key>
    <string>${HUB_BASE_URL:-}</string>
    <key>AI_API_KEY</key>
    <string>${AI_API_KEY:-}</string>
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

  local i=0
  while (( i < 10 )); do
    [[ "$(_check_health "$TTS_PORT")" == "200" ]] && break
    sleep 1; i=$(( i + 1 ))
  done

  echo ""
  echo "✓ TTS 서버 설치 완료"
  echo ""
  echo "  다음으로 코딩 도구별 hook을 등록하세요:"
  echo "    ./install.sh claude            # Claude Code"
  echo "    ./install.sh codex             # Codex CLI"
  echo "    ./install.sh opencode          # OpenCode"
  echo "    ./install.sh claude opencode   # 복수 등록"
  echo ""
  echo "  서비스 제어:"
  echo "    launchctl start $LAUNCHD_LABEL"
  echo "    launchctl stop  $LAUNCHD_LABEL"
  echo "    ./server.sh logs"
}

do_uninstall() {
  if _launchd_loaded; then
    echo "LaunchAgent 언로드 중..."
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  fi
  if [[ -f "$LAUNCHD_PLIST" ]]; then
    rm -f "$LAUNCHD_PLIST"
    echo "✓ LaunchAgent 제거 완료"
  else
    echo "LaunchAgent가 등록되지 않았습니다."
  fi
  echo ""
  echo "  hook 제거가 필요하면:"
  echo "    ./install.sh --uninstall claude"
  echo "    ./install.sh --uninstall claude codex opencode"
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
  pause)     "$VENV_PY" -m hook_voice control pause ;;
  resume)    "$VENV_PY" -m hook_voice control resume ;;
  flush)     "$VENV_PY" -m hook_voice control flush ;;
  skip)      "$VENV_PY" -m hook_voice control skip ;;
  *)
    echo "사용법: $(basename "$0") [start|stop|restart|status|logs [N]|install|uninstall|pause|resume|flush|skip]"
    exit 1
    ;;
esac
