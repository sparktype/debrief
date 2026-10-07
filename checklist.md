# 코드 오너십 노티 체크리스트

목적: 코드를 개발·분석한 턴에서 인지 부채를 줄이도록, 사용자가 직접 확인해야 할 핵심을 턴 브리핑에 녹인다.

- [x] 실패 테스트: VoiceCatalog 훅 컨텍스트(UserPromptSubmit < 400자 유지, SessionStart)
- [x] 실패 테스트: 스킬(EmbeddedTemplates), MCP speak 도구 설명
- [x] 구현: VoiceCatalog.context / companionSpeakSkillMarkdown / speakToolDefinition
- [x] 문서: CLAUDE.md, README/DEVELOPER/ONBOARDING, reflective-companion 스펙 errata
- [x] `./scripts/with-xcode.sh swift test` + release 빌드
- [x] 커밋

## 2026-10-07 categoryVoices 연결
- [x] 실패하는 테스트 먼저(voice_catalog 5건, hook_engine 1건)
- [x] `VoiceCatalog::context_with_voices` 추가, `context`는 빈 맵으로 위임
- [x] `HookEngine`이 설정의 `category_voices`를 넘김
- [x] README 설정 표 갱신
- [x] cargo test --workspace 253건 통과, clippy -D warnings 통과, release 빌드 성공
- [ ] 릴리스 후 sparktype/claude-plugins의 debrief-tune·debrief-voices 스킬을 "동작함"으로 정정
- [ ] voiceSpeeds 연결 여부 결정

## 2026-10-07 의존성 업그레이드
- [x] cargo-audit 설치, 업그레이드 전 `cargo audit` 취약점·경고 없음(197개 크레이트, 권고 1293건)
- [x] `cargo update`로 호환 업데이트 5개 반영(cc, libc, objc2, powerfmt, zeroize)
- [x] ort 요구 버전을 잠금과 같은 rc.13으로 맞춤
- [x] 업그레이드 후 test 253건·clippy·release 빌드·`cargo audit` 통과
- [ ] sha2 0.11 업그레이드는 보류(7개 파일 약 54곳, 설치·무결성 경로)
