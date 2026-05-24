#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/voice-persona"
REPO_URL="https://github.com/sparktype/voice-persona"
LAUNCHD_PLIST_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_LABEL="com.voice-persona.tts-player"
PLIST_FILE="${LAUNCHD_PLIST_DIR}/${LAUNCHD_LABEL}.plist"
HOOKS_SETTINGS="${HOME}/.claude/settings.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info() { echo -e "${BLUE}[i]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; exit 1; }

# ── [1/7] 환경 확인 ──────────────────────────────────────────────────────────
echo ""
info "[1/7] 환경 확인 중..."

[[ "$(uname -m)" != "arm64" ]] && err "Apple Silicon(M1/M2/M3/M4) Mac에서만 실행 가능합니다."

OS_VER=$(sw_vers -productVersion)
MAJOR=$(echo "$OS_VER" | cut -d. -f1)
[[ "$MAJOR" -lt 13 ]] && err "macOS 13(Ventura) 이상이 필요합니다. 현재: $OS_VER"

if ! command -v node &>/dev/null; then
  err "Node.js가 없습니다. https://nodejs.org 에서 설치하세요."
fi
NODE_VER=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
[[ "$NODE_VER" -lt 18 ]] && err "Node.js 18 이상이 필요합니다. 현재: $(node --version)"

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

ok "환경 확인 완료 (macOS $OS_VER, Node $(node --version), Python $(python3 --version))"

# ── [2/7] 저장소 클론/업데이트 ───────────────────────────────────────────────
echo ""
info "[2/7] 저장소 준비 중..."

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

# ── [3/7] Node.js 빌드 ───────────────────────────────────────────────────────
echo ""
info "[3/7] Node.js 패키지 설치 및 빌드 중..."

npm ci --silent || err "npm ci 실패."
npm run build || err "빌드 실패."
ok "빌드 완료"

# ── [4/7] Python 환경 ────────────────────────────────────────────────────────
echo ""
info "[4/7] Python 가상환경 및 패키지 설치 중..."

python3 -m venv tts-venv || err "Python venv 생성 실패."
tts-venv/bin/pip install -q --upgrade pip
tts-venv/bin/pip install -q mlx-audio edge-tts fastapi uvicorn || \
  err "Python 패키지 설치 실패."
ok "Python 환경 준비 완료"

# ── [5/7] MLX 모델 캐시 (선택) ───────────────────────────────────────────────
echo ""
info "[5/7] MLX Qwen3-TTS 모델 캐시 확인 중..."

SKIP_MODEL=false
for arg in "$@"; do [[ "$arg" == "--skip-model" ]] && SKIP_MODEL=true; done

if [[ "$SKIP_MODEL" == "false" ]]; then
  echo ""
  echo "MLX Qwen3-TTS 모델을 다운로드합니다 (약 800MB)."
  echo "이 단계를 건너뛰려면 Ctrl+C 후 '--skip-model' 옵션으로 재실행하세요."
  read -r -p "다운로드하시겠습니까? [Y/n] " REPLY
  REPLY="${REPLY:-Y}"
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    tts-venv/bin/python3 -c "
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

# ── [6/7] Claude Code hooks 등록 ─────────────────────────────────────────────
echo ""
info "[6/7] Claude Code hooks 등록 중..."

register_hooks() {
  local settings_file="$HOOKS_SETTINGS"
  mkdir -p "$(dirname "$settings_file")"

  node -e "
const fs = require('fs');
const path = '$settings_file';
const installDir = '$INSTALL_DIR';

let config = {};
try { config = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}

config.hooks = config.hooks || {};

const hookDefs = {
  Stop: [{ matcher: '', hooks: [{ type: 'command', command: installDir + '/hooks/stop.sh', timeout: 15 }] }],
  SubagentStop: [{ matcher: '', hooks: [{ type: 'command', command: installDir + '/hooks/subagent-stop.sh', timeout: 15 }] }],
  UserPromptSubmit: [{ matcher: '', hooks: [{ type: 'command', command: installDir + '/hooks/prompt-submit.sh', timeout: 10 }] }],
  SessionStart: [{ matcher: '', hooks: [{ type: 'command', command: installDir + '/hooks/session-start.sh', timeout: 10 }] }],
};

for (const [event, def] of Object.entries(hookDefs)) {
  if (!config.hooks[event]) {
    config.hooks[event] = def;
  } else {
    const exists = config.hooks[event].some(h =>
      h.hooks && h.hooks.some(hh => hh.command && hh.command.includes('voice-persona'))
    );
    if (!exists) config.hooks[event].push(...def);
  }
}

fs.writeFileSync(path, JSON.stringify(config, null, 2));
console.log('hooks 등록 완료');
"
}
register_hooks || warn "hooks 등록 실패. 수동 등록이 필요합니다."
ok "Claude Code hooks 등록 완료"

# ── [7/7] TTS Player LaunchAgent 등록 ────────────────────────────────────────
echo ""
info "[7/7] TTS Player LaunchAgent 등록 중..."

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
    <string>/bin/bash</string>
    <string>${INSTALL_DIR}/tts_server/tts_player.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/voice-persona-player.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/voice-persona-player.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE" 2>/dev/null || warn "LaunchAgent 등록 실패. 수동 실행: bash ${INSTALL_DIR}/tts_server/tts_player.sh"
ok "TTS Player LaunchAgent 등록 완료"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ voice-persona 설치 완료${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  작동 확인 : node ${INSTALL_DIR}/dist/index.js test"
echo "  설정 파일 : ~/.voice-persona.json (없으면 기본값 사용)"
echo "  제거      : bash ${INSTALL_DIR}/uninstall.sh"
echo ""
echo "  Claude Code를 재시작하면 자동으로 음성이 활성화됩니다."
echo ""
