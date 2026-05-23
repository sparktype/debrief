#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행

# stdin에서 hook 데이터 읽기
HOOK_DATA=$(cat)
# last_assistant_message 필드에서 직접 텍스트 추출
TEXT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('last_assistant_message', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# 텍스트가 없으면 종료
if [ -z "$TEXT" ]; then
  exit 0
fi

# siren-mcp hook 모드로 실행 — hook timeout과 무관하게 TTS가 끝까지 재생되도록 분리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" hook "$TEXT" > /dev/null 2>&1 &
disown
exit 0
