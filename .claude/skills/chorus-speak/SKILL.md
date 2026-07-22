---
name: chorus:speak
description: "관조 도우미 TTS. 필요할 때만 짧은 관찰+다음 한 걸음. lane/emotion 선택. 침묵 허용."
---

# chorus:speak

턴 끝 **관조 도우미** 한 줄. 화면 목록을 읽는 수준이면 **말하지 않음**.

## 도구

| 환경 | 이름 |
|------|------|
| Claude | `mcp__chorus__speak` |
| Grok | `chorus__speak` |
| Codex | `speak` |

## 문장

관찰 + 의미 + 다음 한 걸음(또는 쉼). 파일/체크리스트/본문 복붙 금지.

## 인자

```json
{
  "text": "관찰. 의미와 다음 한 걸음.",
  "voice": "F1",
  "speed": 0.93,
  "volume": 0.85,
  "lane": "companion",
  "emotion": "neutral"
}
```

- `lane`: companion(기본) / work  
- `emotion`: neutral · warm · focused · concerned · relieved · tired  
- 메뉴 **도우미 음성** off면 companion 재생 안 됨  
