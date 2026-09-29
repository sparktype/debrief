---
name: debrief:speak
description: "사용자에게 보이는 턴이 끝날 때 debrief로 한 줄 브리핑. 바뀐 점과 다음 행동."
---

# debrief:speak

사용자에게 보이는 턴이 끝나면 **한 번** 말한다. 두 문장, 사용자 언어: **무엇이 바뀌었는지**, 그다음 **다음 행동 하나**(또는 기다림). 문장은 에이전트가 쓴다.

새 사실도 다음 행동도 없으면 도구를 생략한다 (Silence only).

## 도구

| 환경 | 이름 |
|------|------|
| Claude | `mcp__debrief__speak` |
| Grok | `debrief__speak` |
| Codex | `speak` |

## 문장

파일 목록, A/B/C 체크리스트, 채팅 본문 복붙 금지. `lane=companion`, voice **F1**, speed ~0.93, volume ~0.85.

## 인자

```json
{
  "text": "무엇이 바뀌었는지. 다음 행동은 이것.",
  "voice": "F1",
  "speed": 0.93,
  "volume": 0.85,
  "lane": "companion",
  "emotion": "neutral"
}
```

- `lane`: companion(기본) / work
- `emotion`: neutral · warm · focused · concerned · relieved · tired
- 서브에이전트는 사용자에게 브리핑하지 않는다. 말하면 `priority=subagent`, `lane=work`, 사실 한 줄.
- 메뉴 **도우미 음성** off면 companion 재생 안 됨
