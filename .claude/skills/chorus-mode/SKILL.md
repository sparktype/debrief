---
name: chorus:mode
description: "chorus TTS 모드 프리셋을 안내합니다. /chorus:mode 를 실행하면 현재 모드 의미와 메뉴바 변경 방법을 설명합니다."
---

# chorus:mode — 음성 모드 안내

Chorus 모드는 **메뉴바 → 모드**에서만 변경합니다. 사용자 CLI나 Python 런타임은 없습니다.

## 모드 효과 (MCP `speak` 기준)

| 모드 | 효과 |
|------|------|
| `normal` | 기본. `main`·`subagent` 모두 재생, 볼륨 천장 1.0 |
| `focus` | `priority=subagent` 발화 억제. 메인 턴만 재생 |
| `quiet` | 볼륨 천장 0.45 + 서브에이전트 억제 |
| `verbose` | 서브에이전트 포함, 볼륨 천장 1.0 |
| `night` | 볼륨 천장 0.20 + 서브에이전트 억제 |

음소거는 **메뉴바 → 음소거**입니다. `priority`는 MCP `speak` 선택 인자이며 생략 시 `main`입니다.

## 진행 방식

1. 사용자에게 메뉴바에서 모드를 고르도록 안내합니다.
2. 에이전트는 모드를 바꾸지 않습니다 (파일 직접 편집 금지).
3. 서브에이전트 발화를 허용/억제하려면 해당 에이전트가 `speak`에 `priority: "subagent"`를 넣는지 확인합니다.
