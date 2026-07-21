---
name: chorus:mute
description: "chorus TTS 음소거를 안내합니다. /chorus:mute 실행 시 메뉴바에서 음소거를 토글하도록 안내합니다."
---

# chorus:mute — 음소거 안내

Chorus 음소거는 **메뉴바 아이콘 → 음소거 / 음소거 해제**에서만 토글합니다.

- 사용자 CLI (`chorus mute`)와 Python (`hook_voice`)은 **제거되었습니다**.
- 에이전트가 설정 파일을 직접 수정하지 마세요.
- 음소거 중에는 MCP `speak` 요청이 큐에 들어와도 재생되지 않습니다.

사용자에게 메뉴바에서 음소거를 토글해 달라고 안내하세요.
