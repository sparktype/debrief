# 체크리스트 — 다시 듣기 · 결정 대기 · 모드 지침 · 효과음 · 압축 알림

스펙: `docs/superpowers/specs/2026-10-14-communication-channels-design.md`
계획: `docs/superpowers/plans/2026-10-14-communication-channels.md`

- [ ] 1. Earcon 사인파 생성 (`earcon.rs`)
- [ ] 2. SpeechRequest `decision`·`cue`·`replayed`, 발화 코덱
- [ ] 3. ModePolicy 결정 대기 예외
- [ ] 4. SpeechQueue 결정 우선·`clear`·`enqueue_replay`
- [ ] 5. 데몬 효과음 재생·기록·`earcons` 설정
- [ ] 6. 제어 프레임(`Control`/`Inbound`)·데몬 `control`
- [ ] 7. CLI `skip [--all]`·`replay [n]`
- [ ] 8. MCP `intent`·응답 `mode`/`muted`
- [ ] 9. 훅 context 모드 지침(`load_effective`, `(dnd)`)
- [ ] 10. PreCompact·PostCompact, 알림별 효과음, 설치 목록
- [ ] 11. 스킬·CLAUDE.md·README·ONBOARDING·CHANGELOG
- [ ] 12. `cargo test --workspace` · `clippy -D warnings` · `cargo build --release`
- [ ] 13. 수동 검증(night에서 결정 대기, replay/skip, 자동 압축) 결과 기록
