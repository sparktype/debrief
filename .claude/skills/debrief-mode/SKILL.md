---
name: debrief:mode
description: "debrief TTS 모드 프리셋을 안내합니다. /debrief:mode 를 실행하면 현재 모드와 debrief mode 변경 방법을 설명합니다."
---

# debrief:mode — 음성 모드 안내

현재 모드는 `debrief mode`로 보고, `debrief mode <mode>`로 바꿉니다. 설정 파일은 직접 고치지 않습니다.

## 모드 효과 (MCP `speak` 기준)

| 모드 | 효과 |
|------|------|
| `normal` | 기본. `main`·`subagent` 모두 재생, 볼륨 천장 1.0 |
| `focus` | `priority=subagent` 발화 억제. 메인 턴만 재생 |
| `quiet` | 볼륨 천장 0.45 + 서브에이전트 억제 |
| `verbose` | 서브에이전트 포함, 볼륨 천장 1.0 |
| `night` | 볼륨 천장 0.20 + 서브에이전트 억제 |

음소거는 `debrief mute`입니다. `priority`는 MCP `speak` 선택 인자이며 생략 시 `main`입니다.

## 진행 방식

1. `debrief mode`로 현재 값을 확인합니다.
2. 바꾸려면 `debrief mode normal|focus|quiet|verbose|night`를 실행합니다. config.json은 직접 고치지 않습니다.
3. 서브에이전트 발화를 허용/억제하려면 해당 에이전트가 `speak`에 `priority: "subagent"`를 넣는지 확인합니다.
