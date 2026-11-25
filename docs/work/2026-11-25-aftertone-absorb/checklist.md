# aftertone 흡수 체크리스트 (2026-11-25)

계획: aftertone(github.com/omarelkhal/aftertone, 008c33a) 분석에서 뽑은 6개 항목을 흡수한다. 요약 훅(Stop 추출)·동시 발화는 제품 경계상 흡수하지 않는다. 청취 검증이 필요한 항목(2·5·6)은 기본값을 현재 동작으로 두고 설정으로만 켠다.

- [x] A1. doctor/status가 소켓에 실제 연결해 응답 여부를 판정 (`socket.unreachable`)
- [x] A4. 발화별 지연 기록(대기·첫 문장 합성·첫 소리) + status에 최근 p50/p95
- [x] B2. 디노이징 단계 수 설정 `synthesisSteps`(기본 8 유지)
- [x] B5. 감정별 문장부호 억양 `prosodyPunctuation`(기본 꺼짐)
- [x] B6. night 모드 `<whisper>` `nightWhisper`(기본 꺼짐)
- [x] C3. 세션별 음소거 `debrief session off|on|list|clear` (다음 프롬프트의 세션에 적용)
- [x] 병합: A·B·C 브랜치를 main에 병합, 충돌 해결
- [x] 문서: CLAUDE.md 제품 경계·README·ONBOARDING 갱신
- [x] 마무리: `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release`
- [x] 사용자 청취·수동 검증 가이드 전달 (단계 5, 문장부호 켬, 목소리 F1 고정, 속삭임 끔)
