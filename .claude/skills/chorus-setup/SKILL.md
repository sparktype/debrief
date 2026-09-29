---
name: chorus:setup
description: "Chorus 설치·복구 안내. MCP install 또는 skill chorus-install을 우선합니다."
---

# chorus:setup

우선 skill **chorus-install** 또는 MCP **`install`**:

| 호스트 | 도구 |
|--------|------|
| Claude | `mcp__chorus__install` |
| Grok | `chorus__install` |
| Codex | `install` |

## Claude Code

```bash
brew install sparktype/tap/chorus
chorus install --claude --repair
```

1. Claude 재시작 → `mcp__chorus__speak` / `mcp__chorus__install`
2. 턴 종료: skill **chorus-speak** — 바뀐 점, 다음 행동 한 줄

## Grok

```bash
chorus install --grok --repair
```

1. **`/mcps`**
2. skill **chorus-speak** → `chorus__speak` (바뀐 점, 다음 행동 한 줄)

## 공통

- 음소거·모드·진단·시작/중지·종료는 **메뉴바만**
- 전체 호스트: `chorus install --repair`
