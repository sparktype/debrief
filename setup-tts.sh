#!/usr/bin/env bash
# chorus TTS 환경 자동 설치 스크립트

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
VENV_DIR="${PROJECT_DIR}/.venv"
SUPERVISOR_PY="${PROJECT_DIR}/tts_server/supervisor.py"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.voice-persona.tts-server.plist"
MODEL_ID="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
LABEL="com.voice-persona.tts-server"

echo "======================================================"
echo " voice-persona TTS 설치 스크립트"
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

# ── 2. .venv 생성 ────────────────────────────────────────────────────────
step "가상환경(.venv) 준비"

if [[ -d "${VENV_DIR}" ]]; then
  ok ".venv가 이미 존재합니다 — 스킵"
else
  python3 -m venv "${VENV_DIR}"
  ok ".venv 생성 완료"
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

# ── 5. supertonic 설치 (Supertonic 온디바이스 TTS) ─────────────────────────
step "supertonic 설치"

if [ -f "${VENV_DIR}/bin/supertonic" ]; then
  ok "supertonic이 이미 설치되어 있습니다 — 스킵"
else
  "${PIP}" install -q 'supertonic[serve]'
  ok "supertonic 설치 완료"
fi

# ── 6. 모델 사전 다운로드 ───────────────────────────────────────────────────
step "HuggingFace 모델 다운로드 (${MODEL_ID})"

# 실제 HF 캐시 경로를 Python에서 직접 조회 (환경변수 오버라이드 포함)
HF_CACHE_DIR="$("${PYTHON}" -c "from huggingface_hub import constants; print(constants.HF_HUB_CACHE)" 2>/dev/null || echo "${HOME}/.cache/huggingface/hub")"
MODEL_CACHE_NAME="models--$(echo "${MODEL_ID}" | tr '/' '--')"

# 캐시 존재 여부 먼저 확인 — 있으면 네트워크 불필요
if [[ -d "${HF_CACHE_DIR}/${MODEL_CACHE_NAME}" ]]; then
  ok "모델 캐시 확인됨 — 다운로드 스킵"
else
  # venv 내 hf 우선 (pyenv 간섭 방지), 없으면 설치
  if [[ -f "${VENV_DIR}/bin/hf" ]]; then
    HF_BIN="${VENV_DIR}/bin/hf"
  elif [[ -f "${VENV_DIR}/bin/huggingface-cli" ]]; then
    HF_BIN="${VENV_DIR}/bin/huggingface-cli"
  else
    warn "hf를 찾을 수 없어 huggingface_hub를 설치합니다."
    "${PIP}" install -q huggingface_hub
    HF_BIN="${VENV_DIR}/bin/hf"
  fi

  if HF_HUB_OFFLINE=0 "${HF_BIN}" download "${MODEL_ID}" 2>&1; then
    ok "모델 다운로드 완료"
  else
    warn "모델 다운로드 실패. TTS 서버가 시작 시 재시도합니다."
  fi
fi

# ── 7. LaunchAgent plist 생성 ───────────────────────────────────────────────
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
    <string>${VENV_DIR}/bin/python</string>
    <string>${SUPERVISOR_PY}</string>
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
  <string>/tmp/voice-persona-tts.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/voice-persona-tts.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key>
    <string>1</string>
    <key>PATH</key>
    <string>${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HUB_BASE_URL</key>
    <string></string>
    <key>HUB_API_KEY</key>
    <string></string>
  </dict>
</dict>
</plist>
PLIST_EOF

ok "plist 생성 완료: ${PLIST_PATH}"

# ── 8. LaunchAgent 등록 ─────────────────────────────────────────────────────
step "LaunchAgent 등록"

# 이미 등록된 경우 unload 후 재등록
if launchctl list | grep -q "${LABEL}" 2>/dev/null; then
  warn "기존 LaunchAgent 발견 — unload 후 재등록합니다."
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi

launchctl load "${PLIST_PATH}"
ok "LaunchAgent 등록 완료"

# ── 9. Supervisor 즉시 시작 ─────────────────────────────────────────────────
step "Supervisor 시작"

if [[ ! -f "${SUPERVISOR_PY}" ]]; then
  warn "tts_server/supervisor.py를 찾을 수 없습니다. 서버 시작을 건너뜁니다."
else
  launchctl start "${LABEL}" 2>/dev/null || true
  ok "Supervisor 시작 명령 완료 (포트 7777·7788 로딩 중)"
fi

# ── 완료 ────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo -e " ${GREEN}✓ voice-persona TTS 설치가 완료되었습니다${NC}"
echo "======================================================"
echo ""
echo "  모델   : ${MODEL_ID}"
echo "  venv   : ${VENV_DIR}"
echo "  plist  : ${PLIST_PATH}"
echo "  로그   : ${PROJECT_DIR}/.tts_server.log"
echo ""
echo "  상태 확인: ${PROJECT_DIR}/server.sh status"
echo "  서버 로그: tail -f ${PROJECT_DIR}/.tts_server.log"
echo ""
