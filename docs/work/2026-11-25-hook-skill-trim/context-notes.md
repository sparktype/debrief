# 훅·스킬 컨텍스트 다이어트 결정 기록 (2026-11-25)

- 사용자가 네 항목(프롬프트별 지침 축약, speak 스킬 정리, setup 스킬 제거, SessionStart 다듬기)을 모두 골랐다.
- 측정(Claude, 결정 대기 한 줄 포함): UserPromptSubmit 437 → 277자, SessionStart 1,295 → 1,050자.
- UserPromptSubmit에서 뺀 것: 긴 도구 설명(→ 짧은 도구 이름 `tool_name`), "in the user's language", "No file lists… No HTML/JSON". 모두 SessionStart·도구 설명에 남아 있다. 계약 문구와 목소리 페르소나 이름은 테스트가 지켜 남겼다.
- SessionStart에서 뺀 것: "The server keeps that companion voice", 필수/선택 인자 목록(도구 스키마가 알림), 감정 cue 괄호(도구 설명에 있음).
- speak 스킬은 Grok의 유일한 계약이라 감정 기준·intent·모드 규칙은 남기고, JSON 예시와 중복 문장만 뺐다. `companionVoice`를 voice 칸에 안내.
- `debrief-setup` 제거: `RETIRED_SKILL_NAMES`로 설치 기록에 있는 파일만 다룬다. 디지스트가 같으면 파일과 빈 폴더를 지우고, 다르면 preserved로 남긴다(설치 기록에서는 빠짐). Grok setup의 고유 안내(/hooks-trust, 훅이 지침을 넣지 않음, status --line)는 Grok install 스킬로 옮겼다.
- `plugins/debrief/`는 설치기가 쓰지 않는 오래된 사본(메뉴바 시절 문구)이라 이번 범위에서 손대지 않았다.
