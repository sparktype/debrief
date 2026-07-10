#!/bin/zsh -l
# Claude Code UserPromptSubmit hook — knowhow 컨텍스트 주입 + 스킬 추천
PAYLOAD=$(cat)
PROJECT_DIR="/Users/hmc7102758/Develop/Workspaces/chorus"
VENV_PY="$PROJECT_DIR/.venv/bin/python"

# payload 파싱
SESSION_ID=$(echo "$PAYLOAD" | "$VENV_PY" -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null)
CWD=$(echo "$PAYLOAD" | "$VENV_PY" -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)
PROMPT=$(echo "$PAYLOAD" | "$VENV_PY" -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('prompt',''))" 2>/dev/null)

CTX_FILE="${HOME}/.knowhow/session-ctx-${SESSION_ID}.md"

_inject_context() {
    local ctx="$1"
    local escaped
    escaped=$(echo "$ctx" | "$VENV_PY" -c \
      "import sys,json; print(json.dumps(sys.stdin.read()))")
    echo "{\"continue\":true,\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":${escaped}}}"
}

if [ -f "$CTX_FILE" ] && [ -n "$SESSION_ID" ]; then
    # 첫 번째 프롬프트: 저장된 컨텍스트 1회 주입 후 파일 삭제
    CTX=$(cat "$CTX_FILE")
    rm -f "$CTX_FILE"
    _inject_context "$CTX"
elif echo "$PROMPT" | grep -qiE \
  'hmg|사내망|hub api|internal-apigw|clawub|service hub|ssl.*(cert|인증)|엔드포인트|접속.*(설정|정보)'; then
    # HMG 키워드 감지: 추가 검색 후 주입
    if [ -n "$CWD" ]; then
        ENCODED_CWD=$("$VENV_PY" -c \
          "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CWD" 2>/dev/null)
        SEARCH=$(curl -sf --max-time 3 \
          "http://localhost:8765/api/session-context?project_dir=${ENCODED_CWD}" 2>/dev/null)
        if [ -n "$SEARCH" ]; then
            _inject_context "$SEARCH"
        else
            echo '{"continue":true}'
        fi
    else
        echo '{"continue":true}'
    fi
else
    echo '{"continue":true}'
fi

# 기존 hook_voice 백그라운드 실행 (TTS 스킬 추천)
echo "$PAYLOAD" | nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PY" \
  -m hook_voice hook-suggest >> /tmp/voice-notification-debug.log 2>&1 &
disown $!
