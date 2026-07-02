---
name: chorus:mode
description: "chorus TTS 모드 프리셋을 변경합니다. /chorus:mode 를 실행하면 현재 모드를 보여주고 normal·focus·quiet·verbose·night 중 선택해 바로 적용합니다."
---

# chorus:mode — 음성 모드 변경

상황에 맞는 TTS 프리셋을 선택해 즉시 적용합니다.

## 모드 목록

| 모드 | 용도 | minChars | ttsSpeed | 브리지 |
|------|------|----------|----------|--------|
| `normal` | 기본값 | 50 | 1.1 | off |
| `focus` | 집중 작업 — 긴 응답만 읽음 | 120 | 1.05 | off |
| `quiet` | 중요한 것만 — 짧은 응답 건너뜀 | 300 | 1.0 | off |
| `verbose` | 짧은 것도 읽기 + 브리지 WAV | 20 | 1.1 | on |
| `night` | 느리고 조용하게 | 120 | 0.95 | off |

## 진행 방식

1. 현재 모드 확인

```bash
.venv/bin/python -m hook_voice mode show
```

2. 변경할 모드를 AskUserQuestion으로 묻는다.

3. 선택한 모드 적용

```bash
# 예: focus 모드로 변경
.venv/bin/python -m hook_voice mode set focus
```

서버 재시작 없이 다음 hook 호출부터 즉시 반영됩니다.
