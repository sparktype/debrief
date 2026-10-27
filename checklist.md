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

## 2026-10-14 문장 단위 선재생 + 감정 표현
- [x] EmotionProsody: 감정별 문장 사이 쉼(`pause_seconds`)·표현 태그(`expression_tag`) 실패 테스트 → 구현
- [x] TtsBackend: 문장 단위 합성 `synthesize_sentences`(기본 구현은 통째 합성 1회) 테스트 → 구현
- [x] Supertonic: 문장마다 청크(`split_sentences`)로 나눠 준비되는 대로 넘김
- [x] 데몬: 첫 문장 재생 중 다음 문장 합성(겹치기), 2번째 문장부터 감정별 쉼, 표현 태그 앞붙임, 사용자 텍스트의 `<` `>` 제거
- [x] 훅 context: emotion 선택 기준 안내(UserPromptSubmit 400자 제한 유지)
- [x] 문서: CLAUDE.md, debrief-speak 스킬, MCP 도구 설명
- [x] cargo test --workspace 279건, clippy -D warnings, release 빌드 통과
- [x] 실제 모델 첫 문장 준비 시간: 1.13→0.72초, 1.76→1.13초, 1.72→0.74초(36~57% 단축)
- [ ] 설치한 데몬으로 청취 확인(사용자)
- [ ] 커밋

## 2026-10-14 감정 표현 청취 튜닝 (v0.2.2)
- [x] 실패 테스트: 속도 불변, 쉼 값, tired 볼륨 0.75
- [x] EmotionProsody 구현, MCP 테스트 기대값 갱신
- [x] 문서·스킬·도구 설명에서 "pace" 제거
- [x] cargo test 279건, clippy 통과
- [x] 릴리스 v0.2.2, 탭 갱신, 데몬 교체

## 2026-10-18 에이전트 사용성 기능 5개 (1→5 순서)
- [x] 1. 새 프롬프트 제출 시 같은 세션의 companion 브리핑 끊기 (SpeechRequest.session, Control::SkipSession, UserPromptSubmit 훅)
- [x] 2. 발음 사전 (`~/.config/debrief/lexicon`, 합성 직전 단어 치환)
- [x] 3. 대기열 TTL + 서브에이전트 완료 합치기
- [x] 4. 마이크 사용 중이면 자동 quiet (옵트인)
- [x] 5. 호스트 추가 (Gemini CLI)
- [x] 기능마다 cargo test / clippy -D warnings / release 빌드 후 커밋

## 2026-10-27 에이전트 연동 강화 6개 (2→1→4→3→6→5 순서)
- [ ] 2. Codex 새 이벤트: PreCompact·PostCompact(trigger auto)·Interrupt(같은 세션 브리핑 끊기, 턴 종료)
- [ ] 1. 데몬에 닿지 않으면 SessionStart·UserPromptSubmit에서 `systemMessage`로 화면 경고(세션당 10분 쿨다운, Claude·Codex)
- [ ] 4. 음소거 중이거나 데몬 전송 실패 시 훅 알림을 `terminalSequence` 데스크톱 알림으로 대체(Claude)
- [ ] 3. 옵트인 `briefingReminder`: 말없이 끝난 긴 턴의 Stop을 한 번 되돌려 speak를 요청(Claude additionalContext, Codex decision block)
- [ ] 6. `debrief status --line`: statusline용 한 줄
- [ ] 5. 옵트인 `permissionRelay`: Claude Channels 권한 중계 + `debrief allow|deny [id]`
- [ ] 문서: CLAUDE.md·README·CHANGELOG
- [ ] 항목마다 cargo test / clippy -D warnings / release 빌드 후 커밋
