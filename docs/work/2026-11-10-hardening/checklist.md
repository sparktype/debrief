# 하드닝 체크리스트 (2026-11-10)

계획: 조용히 실패하는 경로를 먼저 막고(1–4), 이어서 알림·리뷰 잔여분(5–6)을 처리한다. 항목마다 실패 테스트 → 구현 → `cargo test --workspace` → 커밋.

- [x] 1. 소켓을 Caches에서 Application Support로 이전 (구 경로는 심볼릭 링크로 한시 호환)
- [x] 2. 출력 장치 끊김 시 재생 무한 대기 방지 (스트림 오류 콜백 + 대기 상한)
- [x] 3. `doctor`에 `~/.local/bin` 설치본과 실행 중 바이너리 버전 불일치 검사
- [ ] 4. 모델 다운로드 실패 시 HF 미러 자동 폴백
- [ ] 5. Claude `Notification`의 `agent_completed` 처리
- [ ] 6. 미뤄 둔 리뷰 Minor 정리 (코드로 확인된 것만)
- [ ] 마무리: `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release`
