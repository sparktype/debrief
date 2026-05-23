# 스킬 음성 추천 기능 설계

**날짜**: 2026-05-23  
**프로젝트**: summary-voice-mcp  
**범위**: 사용자의 Claude 사용 습관(transcript 분석)을 기반으로 현재 상황에 맞는 스킬을 voice로 추천

---

## 1. 개요

Claude Code transcript를 HMG LLM API로 분석해 현재 작업 맥락에 맞는 스킬 1개를 선택하고, 기존 TTS 파이프라인으로 음성 안내한다. 세션 시작 및 프롬프트 입력 시 자동 발동되며, 수동 호출용 MCP tool도 추가한다.

---

## 2. 아키텍처

### 실행 흐름

```
[SessionStart hook]
  → transcript 최근 3개 파일, 각 마지막 50줄 읽기
  → skills-catalog.json 로드
  → HMG LLM (gpt-5.4): {skill, reason} JSON 반환
  → 쿨다운 체크 (30분)
  → speak("지금 상황엔 <skill> 스킬이 유용할 것 같아요")
  → last-message.txt 저장 + skill-cooldowns.json 갱신

[UserPromptSubmit hook]
  → stdin에서 현재 프롬프트 텍스트 읽기
  → skills-catalog.json 로드
  → HMG LLM: {skill, reason} JSON 반환
  → 쿨다운 체크 (30분)
  → speak() → 저장

[suggest_skill MCP tool]
  → transcript 읽기 + LLM 분석 (쿨다운 무시)
  → speak() + last-message.txt 저장
  → MCP 응답: "추천: <skill>"

[speak_last MCP tool]
  → last-message.txt 읽기
  → speak() 재실행
  → MCP 응답: "재생 완료"
```

### 상태 저장 경로

| 파일 | 내용 |
|------|------|
| `~/.local/share/summary-voice-mcp/skill-cooldowns.json` | `{ "스킬명": ISO타임스탬프 }` |
| `~/.local/share/summary-voice-mcp/last-message.txt` | 마지막 TTS 재생 텍스트 |
| `skills-catalog.json` (프로젝트 루트) | 스킬명 + 설명 목록 |

hook이 독립 프로세스로 실행되므로 상태는 파일 기반으로 공유한다.

---

## 3. 컴포넌트

| 파일 | 역할 |
|------|------|
| `src/skill-recommender.ts` | transcript 읽기, LLM 호출, 쿨다운 관리, 스킬 추천 |
| `src/last-message-store.ts` | 마지막 TTS 텍스트 저장/읽기 |
| `hooks/session-start.sh` | SessionStart hook — 세션 시작 시 스킬 추천 트리거 |
| `hooks/prompt-submit.sh` | UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천 트리거 |
| `src/index.ts` *(변경)* | `suggest_skill`, `speak_last` MCP tool 추가 + hook CLI 분기 추가 |
| `src/player.ts` *(변경)* | `speak()` 호출 시 `last-message-store.ts`로 텍스트 저장 (stop hook TTS도 `/replay` 대상이 되도록) |
| `skills-catalog.json` | LLM에 전달할 스킬 후보 목록 |

---

## 4. LLM 프롬프트 설계

```
다음은 Claude Code 대화 히스토리 일부입니다:
<transcript>
{최근 transcript 내용}
</transcript>

다음은 사용 가능한 스킬 목록입니다:
<skills>
{skills-catalog.json의 스킬명 + 설명}
</skills>

위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.
반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.
{"skill": "<스킬명>", "reason": "<한 문장 이유>"}
```

응답 파싱 실패 또는 catalog에 없는 스킬 반환 시 조용히 종료한다.

---

## 5. 쿨다운 로직

- 기본값: 30분
- `skill-cooldowns.json`에 `{ "스킬명": "2026-05-23T14:30:00.000Z" }` 형태로 저장
- 현재 시각 - 마지막 추천 시각 < 30분이면 speak 스킵
- `suggest_skill` tool 호출 시 쿨다운 무시 (사용자 명시적 요청)

---

## 6. 에러 처리

모든 실패는 silent fail — 기존 프로젝트 패턴과 동일.

| 상황 | 처리 |
|------|------|
| transcript 파일 없음 | 조용히 종료 |
| LLM API 타임아웃/실패 | 조용히 종료 |
| LLM 응답이 JSON 아님 | 조용히 종료 |
| 반환 스킬이 catalog에 없음 | 조용히 종료 |
| `last-message.txt` 없을 때 `speak_last` 호출 | "재생할 내용이 없어요" speak |
| `speak()` 실패 | 기존 silent fail 유지 |

---

## 7. 테스트

vitest 기존 체계 활용. LLM 호출은 mock 처리.

| 테스트 대상 | 범위 |
|-------------|------|
| `skill-recommender.ts` | LLM 응답 파싱, 쿨다운 계산, catalog 매칭 |
| `last-message-store.ts` | 저장/읽기 단위 테스트 |
| hook 스크립트 | stdin 파싱 smoke test |

---

## 8. 미결 사항

- `skills-catalog.json` 초기 목록: 현재 설치된 superpowers/plugin 스킬 기준으로 수동 작성
- 쿨다운 기본값(30분)은 `.siren.json`에서 오버라이드 가능하도록 `SirenConfig`에 추가 예정
- transcript 경로: `~/.claude/projects/*/transcripts/` 글로브 패턴, 최신 mtime 순 정렬
