# 영어 듣기 모드 체크리스트 (2026-11-13)

계획: 에이전트를 쓰며 자연스럽게 영어 듣기에 익숙해지도록, `debrief english` 스위치 하나로 브리핑·고정 알림을 영어로 바꾸고 사용자가 고른 빠르기로 재생한다. 입력(STT)은 외부 앱 몫이라 범위 밖.

- [x] 0. 설정 필드 `english`(기본 false) · `englishSpeed`(기본 0.9) 추가
- [ ] A. TTS 엔진: 한글이 있으면 `<ko>`, 없으면 `<en>`으로 감싸기
- [ ] B. CLI `debrief english [on|off|toggle]` · `debrief english speed <0.7–2.0>`, 설치 완료 문구 영어화
- [ ] C. 데몬: english면 envelope speed 대신 `englishSpeed`, 한국어 발음 사전 건너뛰기, 서브에이전트 합치기 문구 영어화
- [ ] D. 훅: english면 지침에 영어 브리핑 요청 추가, 고정 알림 문구 영어화
- [ ] E. 문서(CLAUDE.md 제품 경계, README/ONBOARDING) 갱신
- [ ] 마무리: `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release`
