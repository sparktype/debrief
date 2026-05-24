#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/voice-persona"
REPO_URL="https://github.com/sparktype/voice-persona"
LAUNCHD_PLIST_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_LABEL="com.voice-persona.tts-server"
PLIST_FILE="${LAUNCHD_PLIST_DIR}/${LAUNCHD_LABEL}.plist"
HOOKS_SETTINGS="${HOME}/.claude/settings.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info() { echo -e "${BLUE}[i]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; exit 1; }

# ── [1/6] 환경 확인 ──────────────────────────────────────────────────────────
echo ""
info "[1/6] 환경 확인 중..."

[[ "$(uname -m)" != "arm64" ]] && err "Apple Silicon(M1/M2/M3/M4) Mac에서만 실행 가능합니다."

OS_VER=$(sw_vers -productVersion)
MAJOR=$(echo "$OS_VER" | cut -d. -f1)
[[ "$MAJOR" -lt 13 ]] && err "macOS 13(Ventura) 이상이 필요합니다. 현재: $OS_VER"

if ! command -v python3 &>/dev/null; then
  err "Python 3.11+가 없습니다. 'brew install python@3.11' 로 설치하세요."
fi
PY_VER=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)" 2>/dev/null)
[[ "$PY_MAJOR" -lt 3 || ("$PY_MAJOR" -eq 3 && "$PY_VER" -lt 11) ]] && \
  err "Python 3.11 이상이 필요합니다. 현재: $(python3 --version)"

if ! command -v claude &>/dev/null; then
  warn "Claude Code CLI가 없습니다. https://claude.ai/code 에서 설치하세요."
  warn "Claude Code 없이도 설치는 계속됩니다."
fi

ok "환경 확인 완료 (macOS $OS_VER, Python $(python3 --version))"

# ── [2/6] 저장소 클론/업데이트 ───────────────────────────────────────────────
echo ""
info "[2/6] 저장소 준비 중..."

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "기존 설치를 업데이트합니다: $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only || warn "git pull 실패. 수동 업데이트 필요."
else
  info "저장소를 클론합니다: $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR" || err "저장소 클론 실패."
fi
cd "$INSTALL_DIR"
ok "저장소 준비 완료"

# ── [3/6] Python 환경 ────────────────────────────────────────────────────────
echo ""
info "[3/6] Python 가상환경 및 패키지 설치 중..."

python3 -m venv .venv || err "Python venv 생성 실패."
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q mlx-audio edge-tts fastapi uvicorn 'supertonic[serve]' || \
  err "Python 패키지 설치 실패."
ok "Python 환경 준비 완료"

# ── [4/6] MLX 모델 캐시 (선택) ───────────────────────────────────────────────
echo ""
info "[4/6] MLX Qwen3-TTS 모델 캐시 확인 중..."

SKIP_MODEL=false
for arg in "$@"; do [[ "$arg" == "--skip-model" ]] && SKIP_MODEL=true; done

if [[ "$SKIP_MODEL" == "false" ]]; then
  echo ""
  echo "MLX Qwen3-TTS 모델을 다운로드합니다 (약 800MB)."
  echo "이 단계를 건너뛰려면 Ctrl+C 후 '--skip-model' 옵션으로 재실행하세요."
  read -r -p "다운로드하시겠습니까? [Y/n] " REPLY
  REPLY="${REPLY:-Y}"
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    .venv/bin/python3 -c "
from mlx_audio.tts.utils import load_model
load_model('mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit')
print('모델 다운로드 완료')
" || warn "모델 다운로드 실패. Edge TTS fallback으로 동작합니다."
  else
    warn "모델 다운로드 건너뜀. Edge TTS fallback으로 동작합니다."
  fi
else
  warn "모델 다운로드 건너뜀 (--skip-model). Edge TTS fallback으로 동작합니다."
fi

# ── [5/6] Claude Code hooks 등록 ─────────────────────────────────────────────
echo ""
info "[5/6] Claude Code hooks 등록 중..."

register_hooks() {
  local settings_file="$HOOKS_SETTINGS"
  mkdir -p "$(dirname "$settings_file")"
  local install_dir="$INSTALL_DIR"

  python3 - <<PYEOF
import json, os, sys
path = "$settings_file"
install_dir = "$install_dir"

try:
    with open(path) as f:
        config = json.load(f)
except Exception:
    config = {}

hooks = config.setdefault("hooks", {})

hook_defs = {
    "Stop": {"timeout": 15, "script": "stop.sh"},
    "SubagentStop": {"timeout": 15, "script": "subagent-stop.sh"},
    "UserPromptSubmit": {"timeout": 10, "script": "prompt-submit.sh"},
    "SessionStart": {"timeout": 10, "script": "session-start.sh"},
}

for event, meta in hook_defs.items():
    cmd = f"{install_dir}/hooks/{meta['script']}"
    entry = {"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": meta["timeout"]}]}
    lst = hooks.setdefault(event, [])
    if not any(
        hh.get("command", "").startswith(install_dir)
        for h in lst for hh in h.get("hooks", [])
    ):
        lst.append(entry)

with open(path, "w") as f:
    json.dump(config, f, indent=2)
print("hooks 등록 완료")
PYEOF
}
register_hooks || warn "hooks 등록 실패. 수동 등록이 필요합니다."
ok "Claude Code hooks 등록 완료"

# ── [6/6] TTS Supervisor LaunchAgent 등록 ────────────────────────────────────
echo ""
info "[6/6] TTS Supervisor LaunchAgent 등록 중..."

mkdir -p "$LAUNCHD_PLIST_DIR"

cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/.venv/bin/python</string>
    <string>${INSTALL_DIR}/tts_server/supervisor.py</string>
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
  <key>StandardOutPath</key>
  <string>${INSTALL_DIR}/.tts_server.log</string>
  <key>StandardErrorPath</key>
  <string>${INSTALL_DIR}/.tts_server.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${INSTALL_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE" 2>/dev/null || warn "LaunchAgent 등록 실패. 수동 실행: ${INSTALL_DIR}/server.sh start"
launchctl start "${LAUNCHD_LABEL}" 2>/dev/null || true
ok "TTS Supervisor LaunchAgent 등록 완료"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ voice-persona 설치 완료${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  상태 확인 : ${INSTALL_DIR}/server.sh status"
echo "  서버 로그 : tail -f ${INSTALL_DIR}/.tts_server.log"
echo "  설정 파일 : ~/.voice-persona.json (없으면 기본값 사용)"
echo "  제거      : bash ${INSTALL_DIR}/uninstall.sh"
echo ""
echo "  Claude Code를 재시작하면 자동으로 음성이 활성화됩니다."
echo ""
