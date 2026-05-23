# EdgeTTS 통합 설계

**날짜**: 2026-05-23  
**상태**: 승인됨  
**범위**: `src/player.ts`, `setup-tts.sh`

---

## 배경 및 목적

현재 siren-mcp의 TTS 1순위는 MLX 기반 FastAPI 상주 서버(localhost:7777)다. 이 구조는 모델 로딩 시간(수십 초)과 서버 기동 불안정이라는 단점이 있다. EdgeTTS(Microsoft Edge 동일 백엔드)는 모델 로딩 없이 즉시 응답하며, 한국어 Neural 음성 품질이 MLX Qwen3-TTS보다 자연스럽다. 오프라인 환경 대비를 위해 MLX는 폴백으로 유지한다.

**적합성 판단**:
- 무료, API 키 불필요
- 개인 사용, 트래픽 소량 → Microsoft ToS 리스크 무시 가능
- 외부 인터넷 접근 가능

---

## 아키텍처

### 변경 후 폴백 체계

```
speak(text, voice, speed, instruct)
  │
  ├─ 1. EdgeTTS subprocess (온라인 우선)
  │     tts-venv/bin/python3로 edge-tts Python API 실행
  │     → /tmp/siren_edge_*.mp3 생성 → afplay -r <speed>
  │     실패(네트워크 오류·10초 타임아웃) → 2로 폴백
  │
  ├─ 2. HTTP TTS 서버 (localhost:7777, 선택적)
  │     MLX FastAPI 서버가 기동 중인 경우에만 사용
  │     서버 없으면 → 3으로
  │
  ├─ 3. MLX subprocess
  │     tts-venv + Qwen3-TTS 직접 실행
  │     tts-venv 없으면 → 4로
  │
  └─ 4. macOS say (최종 폴백)
```

FastAPI 상주 서버(`tts_server/`)는 제거하지 않고 유지한다. 오프라인 환경에서 MLX를 워밍업해두고 싶을 때 선택적으로 사용할 수 있다.

---

## 컴포넌트 상세

### `speakEdge()` (`src/player.ts`)

`tts-venv/bin/python3 -c` 로 인라인 Python async 스크립트를 실행한다. 별도 스크립트 파일 없이 edge-tts Python API를 호출하여 mp3를 생성하고, `afplay -r <speed>`로 재생한다.

```
speakEdge(text, voice, speed):
  edgeVoice = EDGE_VOICE_MAP[voice] ?? "ko-KR-SunHiNeural"
  outFile = /tmp/siren_edge_<timestamp>.mp3
  python3 -c "edge_tts.Communicate(text, edgeVoice).save(outFile)"
  afplay -r speed outFile
  unlink(outFile)
```

타임아웃: `Promise.race([speakEdge(...), rejectAfter(10000)])` 패턴으로 10초 초과 시 reject → 다음 폴백 진행.

### Voice 매핑 테이블

| config `voice` | EdgeTTS 음성 | 비고 |
|---------------|--------------|------|
| `Sohee` (기본) | `ko-KR-SunHiNeural` | 밝은 여성 |
| `Vivian` | `ko-KR-SunHiNeural` | 동일 매핑 |
| `Serena` | `ko-KR-SunHiNeural` | 동일 매핑 |
| `Ryan` | `ko-KR-InJoonNeural` | 남성 |
| `Aiden` | `ko-KR-HyunsuMultilingualNeural` | 다국어 남성 |
| `Eric` | `ko-KR-InJoonNeural` | 남성 |
| 그 외 | `ko-KR-SunHiNeural` | 기본 폴백 |

### instruct 파라미터 처리

EdgeTTS는 `instruct` 파라미터를 지원하지 않는다. EdgeTTS 경로에서 이 파라미터는 무시된다. MLX 폴백 경로에서는 기존대로 전달된다.

---

## 변경 파일

| 파일 | 변경 내용 |
|------|----------|
| `src/player.ts` | `EDGE_VOICE_MAP` 상수, `speakEdge()` 함수 추가; `speak()` 내 우선순위를 EdgeTTS → HTTP → MLX → say 순으로 조정 |
| `setup-tts.sh` | `pip install -q edge-tts` 한 줄 추가 |
| `tts_server/server.py` | 변경 없음 |
| `src/config.ts` | 변경 없음 |

---

## 에러 처리

EdgeTTS에서 폴백으로 넘어가는 조건:
- 네트워크 오류 (ECONNREFUSED, DNS 실패)
- 10초 타임아웃 초과
- `edge-tts` 패키지 미설치
- Microsoft 서버 비정상 응답

모두 silent fail → 다음 폴백. 기존 TTS 에러 처리 방식과 동일.

---

## 테스트

`tests/player.test.ts`에 기존 mock 패턴(`spawn` mock, `fetch` mock) 활용:

| 케이스 | 검증 |
|--------|------|
| EdgeTTS 성공 | spawn 호출 확인, afplay 인자 확인 |
| EdgeTTS 타임아웃 → HTTP 폴백 | 타임아웃 후 fetch 호출 확인 |
| EdgeTTS 실패 + 서버 없음 → MLX 폴백 | spawn exit 1 + mockFetchDead |
| voice 매핑 | Sohee → ko-KR-SunHiNeural 인자 검증 |
| instruct 미전달 | EdgeTTS 경로에서 instruct 인자 없음 확인 |

---

## 설치 방법

기존 `setup-tts.sh` 실행으로 자동 설치된다. 이미 tts-venv가 있는 경우:

```bash
tts-venv/bin/pip install edge-tts
```
