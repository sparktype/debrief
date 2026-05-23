#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행

HOOK_DATA=$(cat)

# payload에서 last_assistant_message 추출
TEXT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('last_assistant_message', ''), end='')
except Exception:
    pass
" 2>/dev/null)

if [ -z "$TEXT" ]; then
  exit 0
fi

# payload에서 transcript_path 추출
TRANSCRIPT=$(echo "$HOOK_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# transcript.jsonl에서 가장 최근 Agent 툴 호출의 subagent_type 추출
AGENT_TYPE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  AGENT_TYPE=$(python3 -c "
import json, sys
path = sys.argv[1]
agent_type = ''
try:
    with open(path, 'r') as f:
        lines = f.readlines()
    for line in reversed(lines):
        try:
            entry = json.loads(line)
            content = entry.get('content', [])
            if isinstance(content, list):
                for block in content:
                    if (isinstance(block, dict)
                            and block.get('type') == 'tool_use'
                            and block.get('name') == 'Agent'):
                        agent_type = block.get('input', {}).get('subagent_type', '')
                        if agent_type:
                            break
            if agent_type:
                break
        except Exception:
            continue
except Exception:
    pass
print(agent_type, end='')
" "$TRANSCRIPT" 2>/dev/null)
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TEXT를 임시 파일 경유 stdin으로 전달 — Command Injection 방지
# AGENT_TYPE은 에이전트 타입명(특수문자 없음)이므로 인수로 유지
_tmpf=$(mktemp)
printf '%s' "$TEXT" > "$_tmpf"
nohup sh -c 'node "$1" subagent-stop "$2" < "$3"; rm -f "$3"' -- \
  "$SCRIPT_DIR/../dist/index.js" "$AGENT_TYPE" "$_tmpf" > /dev/null 2>&1 &
disown $!
exit 0
