# 체크리스트 — 훅 알림 · 세션 구분 · 방해금지 연동

스펙: `docs/superpowers/specs/2026-10-04-hook-notices-design.md`

- [ ] A. 기반: `HookEvent.cwd`, `HookEventName::PermissionRequest`, `SessionStateStore`, `HookResult.notice`, 러너의 데몬 제출
- [ ] B. 기능 1 권한 요청 알림 (엔진 → 러너)
- [ ] C. 설치기: `HOOK_EVENTS`에 PermissionRequest·Stop 추가, repair/uninstall 테스트 갱신
- [ ] D. 기능 5 긴 턴 완료 알림 (`longTurnSeconds`, speak의 `spoken` 표시)
- [ ] E. 기능 4 멀티 세션 구분 (`sessionLabel`, speak 본문 접두)
- [ ] F. 기능 6 방해금지 연동 (`focusSync`, `debrief focus`, 데몬 유효 모드)
- [ ] G. 문서: CLAUDE.md 제품 경계, 스킬/온보딩 문구, `ONBOARDING.md`
- [ ] H. `cargo test --workspace` · `clippy -D warnings` · `cargo build --release`
- [ ] I. 커밋(기능별)·푸시, 수동 검증 항목을 사용자에게 인계
