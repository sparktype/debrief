#!/usr/bin/env bash
# STT 토글 — Claude Code /listen slash 명령에서 호출
curl -s -X POST http://localhost:7777/stt/toggle \
  && echo '{"continue": true}' \
  || echo '{"continue": false, "error": "STT 서버가 응답하지 않습니다"}'
