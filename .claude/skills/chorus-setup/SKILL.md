---
name: chorus:setup
description: "chorus TTS 설정을 대화형으로 변경합니다. /chorus:setup 을 실행하면 현재 상태를 보여주고 모드·목소리·속도 등을 선택해 바로 적용할 수 있습니다."
---

# chorus:setup — 대화형 TTS 설정

chorus TTS의 현재 상태를 조회하고 런타임에 설정을 변경합니다.

## 진행 방식

### Step 1: 현재 상태 확인

```bash
.venv/bin/python -m hook_voice setup status
```

출력 결과를 사용자에게 보여준다.

---

### Step 2: 변경 항목 선택

다음 중 무엇을 변경할지 AskUserQuestion으로 묻는다.

```
질문: "어떤 설정을 변경할까요?"
options:
  - "모드 변경" — normal·focus·quiet·verbose·night 선택 → /chorus:mode 로 위임
  - "에이전트 목소리 변경" — 역할별 목소리 지정
  - "ttsSpeed 조정" — 재생 속도 직접 입력
  - "기본값으로 초기화" — normal 모드 기본값으로 리셋
  - "현재 상태만 확인" — 변경 없이 종료
```

---

### Step 3: 변경 실행

**모드 변경** → `/chorus:mode` 스킬로 위임

**에이전트 목소리 변경**

```bash
# 현재 목소리 매핑 확인
.venv/bin/python -m hook_voice setup voice list

# 변경 (예: reviewer → M1 스티브)
.venv/bin/python -m hook_voice setup voice set reviewer M1
```

역할: `reviewer` `planner` `builder` `tester` `explorer` `optimizer` `guardian` `ops` `specialist`  
voiceId: `F1`(연아) `F2`(마리) `F3`(제인) `F4`(셰릴) `F5`(리사) `M1`(스티브) `M2`(빌) `M3`(일론) `M4`(리누스) `M5`(팀)

**ttsSpeed 조정**

```bash
# 예: 1.2로 변경 (범위: 0.8 ~ 1.5, 기본 1.1)
.venv/bin/python -m hook_voice config set ttsSpeed 1.2
```

**기본값으로 초기화**

```bash
.venv/bin/python -m hook_voice setup defaults
```

---

### Step 4: 결과 확인

```bash
.venv/bin/python -m hook_voice setup status
```

서버 재시작 없이 다음 hook 호출부터 즉시 적용됩니다.
