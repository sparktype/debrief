#!/bin/bash
# Claude Code SessionStart hook — 세션 시작 시 knowhow 컨텍스트 사전 로드
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENV_PY="$PROJECT_DIR/.venv/bin/python"

# session_id, cwd 추출
SESSION_ID=$(echo "$PAYLOAD" | "$VENV_PY" -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null)
CWD=$(echo "$PAYLOAD" | "$VENV_PY" -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)

# knowhow 서버 호출 (timeout 3초, 실패 시 조용히 스킵)
if [ -n "$SESSION_ID" ] && [ -n "$CWD" ]; then
    ENCODED_CWD=$(python3 -c \
      "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CWD" 2>/dev/null)
    if [ -n "$ENCODED_CWD" ]; then
        RESULT=$(curl -sf --max-time 3 \
          "http://localhost:8765/api/session-context?project_dir=${ENCODED_CWD}" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            mkdir -p ~/.knowhow
            printf '%s' "$RESULT" > ~/.knowhow/session-ctx-${SESSION_ID}.md
        fi
    fi
fi

# 기존 hook_voice 백그라운드 실행
nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" -m hook_voice hook-suggest \
  > /dev/null 2>&1 &
disown $!

echo '{"continue":true,"suppressOutput":true}'
