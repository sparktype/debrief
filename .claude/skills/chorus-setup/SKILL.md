---
name: chorus:setup
description: "Chorus.app 설치·복구와 MCP speak 등록을 안내합니다."
---

# chorus:setup

빌드 트리에서 설치·복구:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
# 또는 ./scripts/with-xcode.sh
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --repair
```

- 음소거·모드·시작/중지·종료는 **메뉴바만** 사용합니다.
- 발화는 MCP 도구 `speak` (서버 `chorus`, Grok: `chorus__speak`).
- Codex: MCP는 `~/.codex/config.toml`, 훅은 `~/.codex/hooks.json` — `/hooks`에서 검토.
- Grok: `~/.grok/config.toml` — 설치 후 `/mcps`로 도구 새로고침.
- 진단은 메뉴바 **진단** 메뉴 또는 진단 요약 복사.
