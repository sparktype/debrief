---
name: setup
description: "chorus TTS 설정을 대화형으로 변경합니다. /setup 을 실행하면 현재 상태를 보여주고 모드·목소리·속도 등을 선택해 바로 적용할 수 있습니다."
---

# chorus Setup

chorus TTS의 현재 상태를 조회하고 런타임에 설정을 변경합니다.

## 진행 방식

1. 현재 상태 조회
2. 사용자가 변경할 항목 선택
3. 해당 명령 실행 후 결과 보고

---

## Step 1: 현재 상태 확인

```bash
.venv/bin/python -m hook_voice setup status
```

출력 결과를 사용자에게 보여준다.

---

## Step 2: 변경 항목 선택

다음 중 무엇을 변경할지 AskUserQuestion으로 묻는다.

```
질문: "어떤 설정을 변경할까요?"
options:
  - "모드 변경" — normal / focus / quiet / verbose / night 중 선택
  - "에이전트 목소리 변경" — 리뷰어·빌더 등 역할별 목소리 지정
  - "ttsSpeed 조정" — 재생 속도 직접 입력
  - "기본값으로 초기화" — .voice.json을 normal 모드 기본값으로 리셋
  - "현재 상태만 확인" — 변경 없이 종료
```

---

## Step 3: 변경 실행

선택에 따라 아래 명령을 실행한다.

### 모드 변경

```bash
# 모드 목록 먼저 보여주기
.venv/bin/python -m hook_voice mode list

# 사용자가 선택한 모드로 변경 (예: focus)
.venv/bin/python -m hook_voice mode set focus
```

모드별 특징:
| 모드 | 용도 | minChars | ttsSpeed |
|------|------|----------|----------|
| `normal` | 기본 | 50 | 1.1 |
| `focus` | 집중 작업 — 긴 응답만 읽음 | 120 | 1.05 |
| `quiet` | 중요한 것만 — 매우 짧은 응답 건너뜀 | 300 | 1.0 |
| `verbose` | 짧은 것도 읽기 + 브리지 WAV | 20 | 1.1 |
| `night` | 느리고 조용하게 | 120 | 0.95 |

### 에이전트 목소리 변경

```bash
# 현재 목소리 매핑 확인
.venv/bin/python -m hook_voice setup voice list

# 사용자가 선택한 역할·목소리로 변경 (예: reviewer → M2 빌)
.venv/bin/python -m hook_voice setup voice set reviewer M2
```

사용 가능한 역할: `reviewer` `planner` `builder` `tester` `explorer` `optimizer` `guardian` `ops` `specialist`  
사용 가능한 voiceId: `F1`(연아) `F2`(마리) `F3`(제인) `F4`(셰릴) `F5`(리사) `M1`(스티브) `M2`(빌) `M3`(일론) `M4`(리누스) `M5`(팀)

### ttsSpeed 조정

```bash
# 예: 1.2로 변경
.venv/bin/python -m hook_voice config set ttsSpeed 1.2
```

권장 범위: `0.8` (느리게) ~ `1.5` (빠르게). 기본값 `1.1`.

### 기본값으로 초기화

```bash
.venv/bin/python -m hook_voice setup defaults
```

---

## Step 4: 결과 확인

변경 후 다시 `setup status`를 실행해 적용됐는지 확인한다.

```bash
.venv/bin/python -m hook_voice setup status
```

서버 재시작 없이 즉시 적용됩니다 (다음 hook 호출부터 반영).
