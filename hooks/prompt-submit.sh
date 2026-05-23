#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천

HOOK_DATA=$(cat)

PROMPT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# 프롬프트가 너무 짧으면 스킵 (인사말 등)
if [ "${#PROMPT}" -lt 10 ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 비동기 실행 — hook timeout과 무관하게 TTS 완료까지 재생
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest "$PROMPT" > /dev/null 2>&1 &
disown $!

exit 0
