---
name: chorus:speak
description: "턴 종료 시 Chorus MCP speak로 짧은 음성 요약을 남깁니다. Claude에서는 mcp__chorus__speak로 보일 수 있습니다."
---

# chorus:speak

턴이 끝나 사용자에게 짧은 음성 요약이 도움이 되면, 채팅 본문이 아니라 MCP 도구를 **한 번** 호출합니다.

## 도구

| 환경 | 이름 |
|------|------|
| Claude Code | `speak` on server `chorus` (often `mcp__chorus__speak`) |
| Codex | `speak` on server `chorus` |
| Grok | `chorus__speak` |

## 인자

| 필드 | 필수 | 값 |
|------|------|-----|
| text | yes | ≤ 800자, 한두 문장 |
| voice | yes | F1…F5, M1…M5 (메인 기본 F1) |
| speed | yes | 0.7–2.0 |
| volume | yes | 0.0–1.0 (보통 0.85) |
| priority | no | `main`(기본) 또는 `subagent` |

서브에이전트 턴에서는 `priority: "subagent"`를 권장합니다.

## 하지 말 것

- 본문에 HTML 주석·speech JSON
- 도구 생략 후 “말했다고” 가정 (생략 = 무음)
- mute/mode를 CLI로 바꾸기 (메뉴바만)

설치·복구: skill `chorus-setup` 또는 `chorus install --claude --repair`.
