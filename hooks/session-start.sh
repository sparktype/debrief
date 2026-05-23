#!/usr/bin/env bash
# Claude Code SessionStart hook — 세션 시작 시 스킬 추천

# stdin 데이터 읽기 (사용하지 않지만 drain 필요)
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 비동기 실행 — hook timeout과 무관하게 TTS 완료까지 재생
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest > /dev/null 2>&1 &
disown $!

exit 0
