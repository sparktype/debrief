#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/voice-persona"
LAUNCHD_LABEL="com.voice-persona.tts-server"
PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
HOOKS_SETTINGS="${HOME}/.claude/settings.json"

GREEN='\033[0;32m'; NC='\033[0m'

echo "voice-persona 제거를 시작합니다..."

# 1. LaunchAgent 중지 + 제거
echo "  LaunchAgent 중지 중..."
launchctl unload "$PLIST_FILE" 2>/dev/null || true
rm -f "$PLIST_FILE"
echo "  LaunchAgent 제거 완료"

# 2. TTS 관련 임시 파일 정리
echo "  임시 파일 정리 중..."
rm -rf /tmp/tts-spool /tmp/voice-persona*.log /tmp/supertonic.log /tmp/voice-persona.lock
echo "  임시 파일 정리 완료"

# 3. ~/.claude/settings.json에서 hooks 제거
if [[ -f "$HOOKS_SETTINGS" ]]; then
  echo "  Claude Code hooks 제거 중..."
  node -e "
const fs = require('fs');
const path = process.argv[1];
let config = {};
try { config = JSON.parse(fs.readFileSync(path, 'utf8')); } catch { process.exit(0); }
if (!config.hooks) { process.exit(0); }
for (const event of Object.keys(config.hooks)) {
  config.hooks[event] = config.hooks[event].filter(h =>
    !(h.hooks && h.hooks.some(hh => hh.command && hh.command.includes('voice-persona')))
  );
  if (config.hooks[event].length === 0) delete config.hooks[event];
}
if (Object.keys(config.hooks).length === 0) delete config.hooks;
fs.writeFileSync(path, JSON.stringify(config, null, 2));
" "$HOOKS_SETTINGS"
  echo "  Claude Code hooks 제거 완료"
fi

# 4. 설치 디렉토리 삭제 확인
echo ""
echo "설치 디렉토리 삭제: $INSTALL_DIR"
read -r -p "삭제하시겠습니까? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  rm -rf "$INSTALL_DIR"
  echo "✓ 삭제 완료"
else
  echo "설치 디렉토리는 유지됩니다."
fi

echo ""
echo -e "${GREEN}✓ voice-persona 제거 완료${NC}"
