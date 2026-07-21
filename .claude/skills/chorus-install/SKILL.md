---
name: chorus:install
description: "Chorus.app 설치·복구. MCP install(mcp__chorus__install) 또는 셸 install --claude --repair를 실행합니다."
---

# chorus:install

## 1순위 — MCP 도구

Chorus MCP가 이미 있으면 도구 **`install`** (`mcp__chorus__install`)을 호출합니다.

```json
{ "hosts": ["claude"], "repair": true }
```

- `hosts` 생략 시 codex·claude·grok 전체
- `repair` 기본값 `true`
- 완료 후 Claude Code **재시작**

## 2순위 — 셸

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair
```

또는:

```bash
'/Applications/Chorus.app/Contents/MacOS/chorus' install --claude --repair
```

## 확인

1. 메뉴바에 Chorus
2. `mcpServers.chorus` / start-family hooks
3. 도구 `speak` · `install` 노출
4. 발화는 skill `chorus-speak`
