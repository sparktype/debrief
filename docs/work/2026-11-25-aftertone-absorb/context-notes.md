# aftertone 흡수 결정 기록 (2026-11-25)

- 요약 훅(Stop에서 답변 추출·휴리스틱 요약)은 흡수하지 않는다. CLAUDE.md 제외 목록(Stop speech extraction, HTML envelope)과 충돌하고, 빠진 브리핑은 `briefingReminder`로 다룬다.
- 동시 발화는 debrief가 이미 앞선다(우선순위 끼어들기, 세션별 끊기, 오래된 발화 버리기, 합치기). aftertone은 단일 대기열 + queue|interrupt뿐.
- 미디어 ducking은 aftertone이 Linux 전용이고 macOS엔 공개 API가 없어 제외. 발화 전 차임은 "일반 브리핑엔 효과음 없음" 기존 결정으로 제외.
- 청취가 필요한 2·5·6은 기본값을 현재 동작으로 두고 설정으로만 켠다. 사용자 청취 뒤 기본값을 바꿀지 정한다.
- 세 서브에이전트(A: 1+4, B: 2+5+6, C: 3)가 각자 worktree에서 작업하고 메인 세션이 병합한다. 문서(CLAUDE.md·README·ONBOARDING)는 충돌을 피하려고 병합 뒤 메인 세션이 갱신한다.
- 세션별 음소거는 터미널 CLI가 현재 세션 id를 모르므로 aftertone 방식(대기 파일 → 다음 UserPromptSubmit 훅이 자기 session id로 적용, 5분 만료)을 쓴다.
- 병합(2026-11-25): B(f972e07, 세 실험 설정을 한 커밋으로) → A(543244b·af2112e) → C(73566f4·193bb55). 충돌 없음, 합친 상태 테스트 368+16 통과.
- 데몬 설정은 `load_effective`(dnd·mic 반영)라 `nightWhisper`의 night 판정은 유효 모드 기준. dnd·mic은 quiet까지만 올리므로 사실상 저장된 night에서만 켜진다.
- C가 훅 알림에 `session`을 붙였다(이전 None). 데몬에서 session을 쓰는 곳은 SkipSession뿐이고 companion만 끊으므로 work 알림은 영향 없음.
- 남긴 한계: session-mutes.json은 파일 잠금 없이 rename만(`shortcut:` 주석). `runtime_installer::is_agent_healthy`는 소켓 파일 존재만 보지만 pid 판정이 함께 걸려 있어 그대로 둠. 엔진이 120자 넘는 문장을 다시 나누면 뒤 조각엔 `<whisper>`가 빠진다.
- 2026-11-25 청취: 같은 47자 문장, 레이블 끔, 대기 0에서 첫 소리 4단계 430ms·5단계 524ms·8단계 777ms. 사용자가 4도 괜찮다고 판정해 `synthesisSteps` 기본값을 8→4로 낮춤(엔진 상수도 4). 첫 측정은 프로젝트 레이블 "debrief. "가 첫 문장이 되어 무효였음 — 지연 비교는 `sessionLabel` 끄고 할 것.
- 2026-11-25 재청취: 4단계 기본값에서 사용자가 "이상한 부분"을 들었고, 5단계로 들으니 괜찮다고 판정 → 기본값 5로 확정(첫 소리 약 0.52초).
