# aftertone 흡수 결정 기록 (2026-11-25)

- 요약 훅(Stop에서 답변 추출·휴리스틱 요약)은 흡수하지 않는다. CLAUDE.md 제외 목록(Stop speech extraction, HTML envelope)과 충돌하고, 빠진 브리핑은 `briefingReminder`로 다룬다.
- 동시 발화는 debrief가 이미 앞선다(우선순위 끼어들기, 세션별 끊기, 오래된 발화 버리기, 합치기). aftertone은 단일 대기열 + queue|interrupt뿐.
- 미디어 ducking은 aftertone이 Linux 전용이고 macOS엔 공개 API가 없어 제외. 발화 전 차임은 "일반 브리핑엔 효과음 없음" 기존 결정으로 제외.
- 청취가 필요한 2·5·6은 기본값을 현재 동작으로 두고 설정으로만 켠다. 사용자 청취 뒤 기본값을 바꿀지 정한다.
- 세 서브에이전트(A: 1+4, B: 2+5+6, C: 3)가 각자 worktree에서 작업하고 메인 세션이 병합한다. 문서(CLAUDE.md·README·ONBOARDING)는 충돌을 피하려고 병합 뒤 메인 세션이 갱신한다.
- 세션별 음소거는 터미널 CLI가 현재 세션 id를 모르므로 aftertone 방식(대기 파일 → 다음 UserPromptSubmit 훅이 자기 session id로 적용, 5분 만료)을 쓴다.
