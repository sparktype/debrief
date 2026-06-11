# Monitor 도구 감지 → 리뷰어 목소리 발화

**날짜**: 2026-06-11  
**상태**: 승인됨

## 요약

Claude가 `Monitor` 도구를 호출한 응답이 완료될 때, 기본 F1(연아) 대신 M2(빌/리뷰어) 목소리로 발화한다.

## 동기

모니터링 지시는 감시·추적 성격의 작업으로, 신중하고 꼼꼼한 느낌의 리뷰어 캐릭터가 더 자연스럽다.

## 아키텍처

### 데이터 흐름

```
Claude가 Monitor 도구 호출
  → PreToolUse hook (matcher: "Monitor")
    → hooks/pre-tool-monitor.sh
      → python -m hook_voice pre-tool-monitor
        → /tmp/tts-monitor-{CLAUDE_CODE_SESSION_ID} 생성

Claude 응답 완료
  → Stop hook → python -m hook_voice hook
    → handle_hook()
      ├─ /tmp/tts-monitor-{session_id} 존재?
      │   YES → speak_agent(summary, voice="M2", ...) → 플래그 삭제
      │   NO  → speak_hook(summary)  [기존 동작]
```

### 플래그 파일

| 항목 | 값 |
|------|----|
| 경로 | `/tmp/tts-monitor-{session_id}` |
| 생성 | `handle_pre_tool_monitor()` |
| 소비 | `handle_hook()` — 발화 후 즉시 삭제 |
| 수명 | tmpfs 자동 소멸 (재부팅 시) |
| 세션당 최대 | 1개 |

## 변경 파일

| 파일 | 변경 유형 | 내용 |
|------|-----------|------|
| `hooks/pre-tool-monitor.sh` | 신규 | PreToolUse Monitor hook 스크립트 |
| `hook_voice/hook_handlers.py` | 수정 | `handle_pre_tool_monitor()` 추가, `handle_hook()` 플래그 확인 로직 추가 |
| `hook_voice/__main__.py` | 수정 | `pre-tool-monitor` subcommand 등록 |
| `.claude/settings.json` | 수정 | PreToolUse hook — matcher: `"Monitor"` 등록 |

## 발화 파라미터

`voice-map.json`의 `reviewer` 카테고리 설정 그대로 사용:

- `voice`: `M2` (빌)
- `synth_speed`: `0.93`
- `steps`: `10`
- `instruct`: `"진지하고 신중하게, 하나씩 꼼꼼히 살펴보듯 말해주세요"`

`speak_agent(summary, voice="M2", port=supertonic_port, speed=tts_speed, instruct=..., steps=10, synth_speed=0.93)`

## 에러 처리

- 세션 ID 없음 → 플래그 파일 생성 건너뜀, 기존 F1 발화 유지
- 플래그 파일 삭제 실패 → 로그만, 발화는 정상 진행
- speak_agent 실패 → DLQ에 push (기존 `handle_subagent_stop`과 동일한 패턴)

## 테스트 시나리오

1. Monitor 도구 호출 → Stop → M2 목소리 발화 확인
2. Monitor 미호출 → Stop → F1 목소리 발화 유지 확인
3. 세션 ID 없는 환경 → 기존 동작 유지 확인
4. 플래그 파일이 이미 존재할 때 중복 생성 → 덮어쓰기 무해 확인
