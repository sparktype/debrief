# 코드 오너십 노티 체크리스트

목적: 코드를 개발·분석한 턴에서 인지 부채를 줄이도록, 사용자가 직접 확인해야 할 핵심을 턴 브리핑에 녹인다.

- [x] 실패 테스트: VoiceCatalog 훅 컨텍스트(UserPromptSubmit < 400자 유지, SessionStart)
- [x] 실패 테스트: 스킬(EmbeddedTemplates), MCP speak 도구 설명
- [x] 구현: VoiceCatalog.context / companionSpeakSkillMarkdown / speakToolDefinition
- [x] 문서: CLAUDE.md, README/DEVELOPER/ONBOARDING, reflective-companion 스펙 errata
- [x] `./scripts/with-xcode.sh swift test` + release 빌드
- [x] 커밋
