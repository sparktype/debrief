# 훅·스킬 컨텍스트 다이어트 체크리스트 (2026-11-25)

계획: 같은 브리핑 계약이 SessionStart·UserPromptSubmit·MCP 도구 설명·스킬 네 곳에 반복된다. 프롬프트마다 들어가는 UserPromptSubmit 지침(437자)을 가장 많이 줄이고, SessionStart는 반복만 덜고, 스킬은 고정 목소리를 반영해 짧게, `debrief-setup`은 없앤다. 계약 문구("Silence only", "what changed", "next action", "ownership", 감정 기준, "debrief mute")는 테스트가 지키므로 남긴다.

- [x] UserPromptSubmit 지침 축약(목표 260자 미만, 짧은 도구 이름)
- [x] SessionStart 지침 다듬기(인자 목록·서버 목소리 유지 문장·cue 괄호 제거)
- [x] debrief-speak 스킬 축약 + `companionVoice` 고정 반영(Claude/Codex 공용, Grok)
- [x] debrief-setup 제거: 템플릿·SKILL_NAMES, 설치 기록에 있고 내용이 같은 기존 파일 삭제, Grok 고유 안내는 Grok install 스킬로 이동
- [x] 문서(README·CLAUDE.md·ONBOARDING) 스킬 목록 갱신
- [x] `cargo test --workspace`, clippy, release, 설치 후 실제 지침 길이 재측정
