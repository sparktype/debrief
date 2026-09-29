---
name: debrief:setup
description: "debrief 설치·복구 안내. MCP install 또는 skill debrief-install을 우선합니다."
---

# debrief:setup

우선 skill **debrief-install** 또는 MCP **`install`**:

| 호스트 | 도구 |
|--------|------|
| Claude | `mcp__debrief__install` |
| Grok | `debrief__install` |
| Codex | `install` |

## Claude Code

```bash
debrief install --claude --repair
```

1. Claude 재시작 → `mcp__debrief__speak` / `mcp__debrief__install`
2. 턴 종료: skill **debrief-speak** — 바뀐 점, 다음 행동 한 줄

## Grok

```bash
debrief install --grok --repair
```

1. **`/mcps`**
2. skill **debrief-speak** → `debrief__speak` (바뀐 점, 다음 행동 한 줄)

## 공통

- 음소거·모드·도우미 음성·진단·시작/중지: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`, `debrief start`, `debrief stop`
- 전체 호스트: `debrief install --repair`
