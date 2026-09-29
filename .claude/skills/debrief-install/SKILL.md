---
name: debrief:install
description: "debrief 데몬 설치·복구. MCP install(mcp__debrief__install) 또는 debrief install --claude --repair를 실행합니다."
---

# debrief:install

## 1순위 — MCP 도구

debrief MCP가 이미 있으면 도구 **`install`** (`mcp__debrief__install`)을 호출합니다.

```json
{ "hosts": ["claude"], "repair": true }
```

- `hosts` 생략 시 codex·claude·grok 전체
- `repair` 기본값 `true`
- 완료 후 Claude Code **재시작**

## 2순위 — 셸

```bash
debrief install --claude --repair
```

## 확인

1. `debrief status`에 프로세스가 실행 중
2. `mcpServers["debrief"]` / start-family hooks
3. 도구 `speak` · `install` 노출
4. 발화는 skill `debrief-speak`
