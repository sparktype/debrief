---
name: chorus:setup
description: "Chorus.app 설치·복구와 Claude Code MCP speak 등록을 안내합니다."
---

# chorus:setup

## Claude Code

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

그다음:

1. `~/.claude/settings.json`에 `mcpServers.chorus` 확인
2. 훅 `SessionStart` / `UserPromptSubmit` / `SubagentStart` 확인
3. Claude Code 재시작 → `speak` 또는 `mcp__chorus__speak` 노출
4. 턴 종료 시 skill `chorus-speak` / MCP speak 한 번 호출

## 공통

```bash
.build/release/chorus install --repair
```

- 음소거·모드·진단·시작/중지·종료는 **메뉴바만**
- Codex: MCP `~/.codex/config.toml`, 훅 `~/.codex/hooks.json`
- Grok: `~/.grok/config.toml` → `/mcps`
