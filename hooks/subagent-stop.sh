#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" subagent-stop > /dev/null 2>&1 &
disown $!; exit 0
