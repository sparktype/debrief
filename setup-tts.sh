#!/usr/bin/env bash
# summary-voice-mcp TTS 환경 자동 설치 스크립트

set -euo pipefail

# ── 색상 출력 헬퍼 ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

step()  { echo -e "\n▶ ${1}..."; }
ok()    { echo -e "  ${GREEN}✓${NC} ${1}"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  ${1}"; }
error() { echo -e "  ${RED}✗${NC}  ${1}" >&2; exit 1; }

# ── 경로 설정 ───────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${PROJECT_DIR}/tts-venv"
START_SH="${PROJECT_DIR}/tts_server/start.sh"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.summary-voice-mcp.tts-server.plist"
MODEL_ID="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
LABEL="com.summary-voice-mcp.tts-server"

echo "======================================================"
echo " summary-voice-mcp TTS 설치 스크립트"
echo " 프로젝트 경로: ${PROJECT_DIR}"
echo "======================================================"

# ── 1. Python 버전 확인 ─────────────────────────────────────────────────────
step "Python 버전 확인"

if ! command -v python3 &>/dev/null; then
  error "python3를 찾을 수 없습니다. Python 3.9 이상을 설치해주세요."
fi

PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")

if [[ "${PY_MAJOR}" -lt 3 ]] || { [[ "${PY_MAJOR}" -eq 3 ]] && [[ "${PY_MINOR}" -lt 9 ]]; }; then
  error "Python ${PY_VERSION} 감지됨. Python 3.9 이상이 필요합니다."
fi

ok "Python ${PY_VERSION} 확인됨"

# ── 2. tts-venv 생성 ────────────────────────────────────────────────────────
step "가상환경(tts-venv) 준비"

if [[ -d "${VENV_DIR}" ]]; then
  ok "tts-venv가 이미 존재합니다 — 스킵"
else
  python3 -m venv "${VENV_DIR}"
  ok "tts-venv 생성 완료"
fi

PIP="${VENV_DIR}/bin/pip"
PYTHON="${VENV_DIR}/bin/python"

# ── 3. mlx-audio 설치 ───────────────────────────────────────────────────────
step "mlx-audio 설치"

if "${PYTHON}" -c "import mlx_audio" &>/dev/null 2>&1; then
  ok "mlx-audio가 이미 설치되어 있습니다 — 스킵"
else
  "${PIP}" install -q mlx-audio
  ok "mlx-audio 설치 완료"
fi

# ── 4. edge-tts 설치 (EdgeTTS 온라인 TTS) ───────────────────────────────────
step "edge-tts 설치"

if "${PYTHON}" -c "import edge_tts" &>/dev/null 2>&1; then
  ok "edge-tts가 이미 설치되어 있습니다 — 스킵"
else
  "${PIP}" install -q edge-tts
  ok "edge-tts 설치 완료"
fi

# ── 5. 모델 사전 다운로드 ───────────────────────────────────────────────────
step "HuggingFace 모델 다운로드 (${MODEL_ID})"

HF_CLI="${VENV_DIR}/bin/huggingface-cli"

if [[ ! -f "${HF_CLI}" ]]; then
  warn "huggingface-cli를 찾을 수 없어 huggingface_hub를 설치합니다."
  "${PIP}" install -q huggingface_hub
fi

# HF_HUB_OFFLINE 전역 설정을 재정의하여 다운로드 허용
if HF_HUB_OFFLINE=0 "${HF_CLI}" download "${MODEL_ID}" 2>&1; then
  ok "모델 다운로드/캐시 확인 완료"
else
  # 다운로드 실패 시 캐시 존재 여부 확인
  HF_CACHE_DIR="${HF_HUB_CACHE:-${HOME}/.cache/huggingface/hub}"
  MODEL_CACHE_NAME="models--$(echo "${MODEL_ID}" | tr '/' '--')"
  if [[ -d "${HF_CACHE_DIR}/${MODEL_CACHE_NAME}" ]]; then
    warn "네트워크 오류 — 기존 캐시를 사용합니다."
  else
    warn "모델 다운로드 실패, 캐시도 없습니다. TTS 서버가 시작 시 다운로드를 시도합니다."
  fi
fi

# ── 6. LaunchAgent plist 생성 ───────────────────────────────────────────────
step "LaunchAgent plist 생성"

mkdir -p "${HOME}/Library/LaunchAgents"

cat > "${PLIST_PATH}" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${START_SH}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <false/>

  <key>StandardOutPath</key>
  <string>/tmp/summary-voice-mcp-tts.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/summary-voice-mcp-tts.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>PROJECT_DIR</key>
    <string>${PROJECT_DIR}</string>
  </dict>
</dict>
</plist>
PLIST_EOF

ok "plist 생성 완료: ${PLIST_PATH}"

# ── 7. LaunchAgent 등록 ─────────────────────────────────────────────────────
step "LaunchAgent 등록"

# 이미 등록된 경우 unload 후 재등록
if launchctl list | grep -q "${LABEL}" 2>/dev/null; then
  warn "기존 LaunchAgent 발견 — unload 후 재등록합니다."
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi

launchctl load "${PLIST_PATH}"
ok "LaunchAgent 등록 완료"

# ── 8. TTS 서버 즉시 시작 ──────────────────────────────────────────────────
step "TTS 서버 시작"

if [[ ! -f "${START_SH}" ]]; then
  warn "tts_server/start.sh를 찾을 수 없습니다. 서버 시작을 건너뜁니다."
  warn "start.sh를 생성한 후 'bash ${START_SH}' 를 실행하거나 재부팅하세요."
else
  bash "${START_SH}"
  ok "TTS 서버 시작 명령 완료"
fi

# ── 완료 ────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo -e " ${GREEN}✓ summary-voice-mcp TTS 설치가 완료되었습니다${NC}"
echo "======================================================"
echo ""
echo "  모델   : ${MODEL_ID}"
echo "  venv   : ${VENV_DIR}"
echo "  plist  : ${PLIST_PATH}"
echo "  로그   : /tmp/summary-voice-mcp-tts.log"
echo ""
echo "  서버 로그 확인: tail -f /tmp/summary-voice-mcp-tts.log"
echo ""
