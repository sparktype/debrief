#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행

# stdin에서 hook 데이터 읽기
HOOK_DATA=$(cat)

# transcript에서 마지막 assistant 메시지 추출
TEXT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    transcript = data.get('transcript', [])
    for msg in reversed(transcript):
        if msg.get('role') == 'assistant':
            content = msg.get('content', '')
            if isinstance(content, list):
                content = ' '.join(
                    c.get('text', '') for c in content if c.get('type') == 'text'
                )
            print(content, end='')
            break
except Exception:
    pass
" 2>/dev/null)

# 텍스트가 없으면 종료
if [ -z "$TEXT" ]; then
  exit 0
fi

# siren-mcp hook 모드로 실행 (TTS 실패해도 0 exit)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$SCRIPT_DIR/../dist/index.js" hook "$TEXT" 2>/dev/null || true
exit 0
