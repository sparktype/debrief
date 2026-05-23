# siren-mcp 설계 문서

**날짜**: 2026-05-23  
**상태**: 승인됨  
**프로젝트**: siren-mcp

---

## 개요

Claude Code의 답변에서 요약·결론을 추출해 음성으로 먼저 전달하는 MCP 서버.  
긴 답변을 읽지 않아도 핵심을 즉시 파악할 수 있도록 한다.

---

## 결정 사항 요약

| 항목 | 결정 |
|------|------|
| TTS 엔진 | OpenAI TTS API |
| 요약 모델 | OpenAI GPT-4o-mini |
| 구현 언어 | TypeScript |
| 통합 방식 | Stop hook 자동 + `/speak` 수동 병행 |
| 트리거 조건 | config 파일로 임계값 설정 가능 |
| 구현 전략 | 단계적 빌드 (Phase 1 → Phase 2) |

---

## 아키텍처

### 전체 데이터 흐름

```
[ Claude Code ]
  │
  ├─ Stop hook (자동) ── 응답 길이 ≥ minChars?
  │                              ├─ Yes → MCP 호출
  │                              └─ No  → 스킵
  │
  └─ /speak 수동 호출 ──────────── 항상 MCP 호출
                 │
                 ▼
        [ siren-mcp MCP Server ]
          │
          ├─ Summarizer ── GPT-4o-mini → "핵심 1~2문장"
          │
          ├─ TTS Engine ── OpenAI TTS API → MP3
          │
          └─ Audio Player ── afplay (macOS) → 🔊
```

### 파일 구조

```
siren-mcp/
  src/
    index.ts       ← MCP 서버 진입점 + tool 등록
    summarizer.ts  ← OpenAI GPT로 요약 추출
    tts.ts         ← OpenAI TTS API 호출
    player.ts      ← 오디오 재생 (afplay)
    config.ts      ← .siren.json 로드
  hooks/
    stop.sh        ← Claude Code Stop hook
  .siren.json      ← 사용자 설정
  package.json
  tsconfig.json
```

### MCP Tool 목록

| Tool | 역할 |
|------|------|
| `speak_text` | 전달한 텍스트 그대로 TTS 재생 |
| `summarize_and_speak` | 텍스트 → GPT 요약 → TTS 재생 |
| `set_config` | 런타임 설정 변경 (on/off, minChars 등) |

---

## Phase 계획

### Phase 1 — 빠른 검증 (목표: 당일)

- MCP 서버 기본 뼈대 (`@modelcontextprotocol/sdk`)
- `speak_text` tool — 텍스트를 `say` 명령으로 즉시 읽기
- `summarize_and_speak` tool — 마지막 3문장 추출 → `say`
- Claude Code `Stop` hook 연결
- `minChars` 임계값으로 짧은 응답 스킵
- OpenAI API 연동 없음 (다음 Phase에서 교체)

### Phase 2 — 고품질 업그레이드

- TTS: `say` → OpenAI TTS API (nova 보이스)
- 요약: 규칙 추출 → GPT-4o-mini 프롬프트
- `.siren.json` config 파일 완성
- `set_config` tool — 런타임 on/off, 설정 변경
- 오디오 큐 (연속 응답 겹침 방지)

---

## Config 스키마 (`.siren.json`)

```json
{
  "autoSpeak": true,
  "minChars": 500,
  "voice": "nova",
  "summaryModel": "gpt-4o-mini",
  "ttsModel": "tts-1",
  "language": "ko"
}
```

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `autoSpeak` | `true` | Stop hook 자동 모드 on/off |
| `minChars` | `500` | 이 길이 이상의 응답만 읽음 |
| `voice` | `"nova"` | OpenAI TTS 보이스 |
| `summaryModel` | `"gpt-4o-mini"` | 요약용 모델 |
| `ttsModel` | `"tts-1"` | TTS 모델 |
| `language` | `"ko"` | 요약 언어 힌트 |

---

## Hook 연결

`~/.claude/settings.json` 또는 프로젝트 `.claude/settings.json` 에 등록:

```json
{
  "hooks": {
    "Stop": [{
      "command": "npx siren-mcp hook",
      "timeout": 10
    }]
  }
}
```

---

## 에러 처리

**핵심 원칙**: TTS 실패가 Claude Code 작업을 방해하면 안 됨.

- 모든 TTS/요약 오류는 silent fail — 로그만 남기고 계속 진행
- OpenAI API 타임아웃 → `say` 폴백 (Phase 2)
- Hook 실패 시 Claude Code에 영향 없음 (`continueOnError: true`)
- `OPENAI_API_KEY` 없으면 서버 시작 시 경고 후 `say` 모드로 동작

---

## 테스트 전략

### Phase 1 검증

1. MCP Inspector로 tool 수동 호출
2. 짧은 텍스트 → `say`로 재생 확인
3. Stop hook 연결 → Claude에게 긴 답변 요청 후 자동 재생 확인

### Phase 2 검증

4. OpenAI TTS MP3 생성 및 재생 확인
5. GPT 요약 품질 확인 (한국어 답변 → 한국어 요약)
6. `minChars` 임계값 동작 확인 (짧은 응답 스킵)
7. 연속 응답 시 오디오 큐 동작 확인

---

## 설치 & 사용 흐름

```bash
# 1. 설치
npm install -g siren-mcp

# 2. API 키 설정
export OPENAI_API_KEY=sk-...

# 3. Claude Code에 MCP 등록
claude mcp add siren -- siren-mcp

# 4. (선택) 자동 Hook 활성화
siren-mcp install-hook

# 5. Claude에게 긴 답변 요청 → 🔊 자동 재생
```
