# 설계: 에이전트별 Supertonic 다성 TTS

**날짜**: 2026-05-23  
**프로젝트**: summary-voice-mcp  
**상태**: 승인됨

---

## 목표

Claude Code 서브에이전트 타입별로 서로 다른 목소리를 사용해 TTS를 발화한다.  
EdgeTTS는 한국어 voice가 사실상 하나(`HyunsuMultilingualNeural`)뿐이므로,  
Supertonic(ONNX 기반 온디바이스 TTS)을 활용해 에이전트 카테고리마다 다른 voice를 할당한다.

---

## 아키텍처

```
─────────── 서브에이전트 응답 ─────────────────────────────
SubagentStop hook (hooks/subagent-stop.sh)
  ↓ stdin payload 파싱
  ↓ transcript.jsonl에서 가장 최근 Agent 툴 호출의 subagent_type 추출
  ↓ voice-router.ts: subagent_type → category → Supertonic voice 이름
  ↓ player.ts speakSupertonic(): POST /v1/audio/speech → supertonic serve (포트 7788)
  ↓ afplay로 재생 → 완료

─────────── 메인 Claude 응답 ──────────────────────────────
Stop hook (hooks/stop.sh) — 기존 그대로 유지
  ↓ extractSummary() → speak() [EdgeTTS → MLX 서버 → say]

─────────── Supertonic 서버 ───────────────────────────────
server.sh / launchd LaunchAgent로 상시 운영 (포트 7788)
  supertonic serve --host 127.0.0.1 --port 7788
```

**역할 분리 원칙**
- 서브에이전트 응답 → `subagent-stop.sh` → Supertonic (카테고리별 다성)
- 메인 Claude 응답 → `stop.sh` → 기존 TTS 체인 (EdgeTTS → MLX → say)
- 두 hook은 독립적으로 동작, 타이밍 충돌 없음

---

## 에이전트 카테고리 및 voice 매핑

| 카테고리 | Supertonic Voice | 목소리 느낌 | 대상 에이전트 |
|---------|-----------------|-----------|-------------|
| reviewer | M2 | 냉철하고 낮은 목소리 | code-reviewer, python-reviewer, security-reviewer 등 |
| planner | M1 | 차분하고 명확한 목소리 | planner, architect, code-architect 등 |
| builder | M4 | 빠르고 가벼운 목소리 | build-error-resolver, tdd-guide 등 |
| explorer | F3 | 호기심 있는 목소리 | Explore, code-explorer, general-purpose 등 |
| default | F1 | 기본 목소리 | 위 카테고리에 없는 모든 에이전트 |

---

## voice-map.json 구조

```json
{
  "supertonic": {
    "port": 7788,
    "lang": "ko"
  },
  "voices": {
    "reviewer": "M2",
    "planner": "M1",
    "builder": "M4",
    "explorer": "F3",
    "default": "F1"
  },
  "categories": {
    "reviewer": [
      "code-reviewer", "python-reviewer", "security-reviewer",
      "typescript-reviewer", "rust-reviewer", "go-reviewer",
      "kotlin-reviewer", "swift-reviewer", "cpp-reviewer",
      "java-reviewer", "csharp-reviewer", "flutter-reviewer",
      "fastapi-reviewer", "database-reviewer", "mle-reviewer",
      "pr-test-analyzer", "code-simplifier"
    ],
    "planner": [
      "planner", "architect", "code-architect", "a11y-architect",
      "plan", "feature-dev"
    ],
    "builder": [
      "build-error-resolver", "dart-build-resolver", "rust-build-resolver",
      "go-build-resolver", "kotlin-build-resolver", "swift-build-resolver",
      "cpp-build-resolver", "java-build-resolver", "tdd-guide",
      "gan-generator", "multi-execute"
    ],
    "explorer": [
      "Explore", "code-explorer", "general-purpose",
      "gitnexus-exploring", "claude-code-guide"
    ]
  }
}
```

**확장 방법**: 새 에이전트는 `categories` 배열에 항목 추가만으로 코드 변경 없이 지원.  
새 카테고리는 `voices`와 `categories`에 항목 추가, `voice-map.json`만 수정.

---

## 에이전트 타입 감지

SubagentStop hook payload에 `subagent_type`이 직접 포함되지 않을 수 있으므로,  
**transcript 파싱**을 주 방법으로 사용한다.

```
subagent-stop.sh
  1. stdin에서 transcript_path 추출
  2. transcript.jsonl 끝에서부터 역방향 탐색
  3. "name": "Agent" 툴 호출 찾아 "subagent_type" 추출
  4. node dist/index.js subagent-stop "<text>" "<agentType>" 호출
  5. voice-router.ts로 voice 결정 → speakSupertonic() 호출
```

payload에 `subagent_type`이 직접 있으면 transcript 파싱을 건너뜀 (fast path).

---

## Supertonic HTTP API

`supertonic serve`는 OpenAI 호환 엔드포인트를 제공한다.

```
POST http://localhost:7788/v1/audio/speech
Content-Type: application/json

{
  "model": "supertonic-3",
  "input": "재생할 텍스트",
  "voice": "M1",
  "response_format": "wav"
}
```

응답: WAV 바이너리 → 임시 파일 저장 → `afplay`로 재생 → 파일 삭제

---

## 폴백 전략

Supertonic 서버가 응답하지 않을 때:
```
speakSupertonic() 실패
  → speakEdge() (EdgeTTS, 기존 로직)
  → speakSubprocess() (MLX/say, 기존 로직)
```

---

## 변경 파일 목록

| 파일 | 변경 | 내용 |
|------|------|------|
| `voice-map.json` | 신규 | 카테고리·voice 매핑 설정 |
| `src/voice-router.ts` | 신규 | agentType → voice 해석 로직 |
| `src/player.ts` | 수정 | `speakSupertonic()` 함수 추가 |
| `src/config.ts` | 수정 | `supertonicPort` 필드 추가 |
| `src/index.ts` | 수정 | `subagent-stop` CLI 분기 추가 |
| `hooks/subagent-stop.sh` | 신규 | SubagentStop hook 스크립트 |
| `server.sh` | 수정 | supertonic serve 시작/종료 관리 |
| `tts_server/supertonic.sh` | 신규 | supertonic 서버 래퍼 스크립트 |
| `tests/voice-router.test.ts` | 신규 | voice-router 단위 테스트 |

**기존 파일 무변경**: `hooks/stop.sh`, `src/summarizer.ts`, `tts_server/server.py`

---

## 제약 및 전제 조건

- Supertonic PyPI 패키지 설치 필요: `pip install 'supertonic[serve]'`
- 첫 실행 시 모델 자동 다운로드 (~260MB, HuggingFace)
- HMG 사내망에서는 HF 다운로드가 차단될 수 있으므로 외부망에서 먼저 실행 권장
- 기존 MLX TTS 서버(포트 7777)와 포트 충돌 없음
