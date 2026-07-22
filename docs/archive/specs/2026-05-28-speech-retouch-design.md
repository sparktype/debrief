# Speech Retouch 설계 — LLM 기반 TTS 텍스트 정제

**날짜**: 2026-05-28  
**작성자**: 박상선 책임매니저  
**상태**: 승인됨

---

## 배경 및 문제

Claude Code 응답 요약본을 EdgeTTS로 발화할 때, `**별표**` → "별표 별표", `API` → "에이 피 아이" 처럼 TTS가 마크다운 기호나 영문 IT 용어를 그대로 읽는 현상이 발생한다.

### 근본 원인

1. `extract_summary`가 LLM 결과에 `sanitize_for_speech`를 적용하지 않아 `**`, `#` 등이 통과됨
2. `_preprocess_for_tts`(발음 사전)가 Supertonic 경로에만 적용되고 EdgeTTS 경로에는 없음
3. LLM이 시스템 프롬프트를 어길 때 마크다운을 반환할 수 있음

---

## 해결 전략 — 접근법 A (명시적 단계 추가)

`retouch_for_speech`를 별도 LLM 호출로 구현하고, `handle_hook` / `handle_subagent_stop`에서 명시적으로 호출한다. `player.py`는 LLM 의존성 없이 순수 오디오 모듈로 유지한다.

---

## 파이프라인 변경

### 메인 응답 (handle_hook)

```
before: extract_summary(text) → speak_hook(summary)
after:  extract_summary(text)
          → retouch_for_speech(summary)
            → speak_hook(retouched)
```

### 서브에이전트 응답 (handle_subagent_stop)

```
before: extract_one_liner(text) → sanitize_for_speech → speak_agent
after:  extract_one_liner(text)
          → retouch_for_speech(one_liner)
            → speak_agent(retouched)
```

---

## 신규 함수 — `retouch_for_speech`

**위치**: `hook_voice/summarizer.py`

```python
async def retouch_for_speech(text: str, model: str = DEFAULT_MODEL) -> str:
    """LLM으로 TTS 발화용 텍스트 정제 — 마크다운 제거, IT 용어 발음 변환."""
    ...
```

### LLM 시스템 프롬프트

```
다음 텍스트를 한국어 TTS 발화에 적합하게 정제하세요.
1. 마크다운 기호(** * # ` [] | > —) 완전 제거
2. 영문 IT 용어를 한국어 발음으로 변환 (API→에이피아이, GPU→지피유, HTTP→에이치티티피)
3. 코드 블록·URL은 '[코드 생략]' / '[링크 생략]'으로
4. 특수 기호(→ ← ≥ ± © ® ™ …) 제거 또는 한국어로
5. <breath> <laugh> <sigh> 같은 Expression Tag는 그대로 보존
6. 의미 변경 없이 정제만 — 새 내용 추가 금지
출력: 정제된 텍스트만, 설명 없이
```

### 파라미터

| 파라미터 | 값 |
|---------|-----|
| `max_completion_tokens` | 300 |
| `temperature` | 0.0 |
| 실패 폴백 | `sanitize_for_speech(text)` |

---

## 즉시 수정 — `extract_summary` 버그

`extract_summary`가 LLM 결과 또는 `_fallback` 결과를 반환하기 전에 `sanitize_for_speech`를 적용한다. `retouch_for_speech`와 독립적으로 적용되는 안전망.

```python
# 변경 전
return result or _fallback(text)

# 변경 후
return sanitize_for_speech(result or _fallback(text))
```

---

## EdgeTTS 경로 발음 처리

`retouch_for_speech`가 `speak_hook` 호출 전에 실행되므로, LLM이 영문 IT 용어를 이미 변환한다. `player.py`에 별도 발음 사전을 적용할 필요가 없다.

`_TECH_PHONETICS`는 `tts_server/server.py`(Supertonic 전용)에 그대로 유지한다. 두 모듈 간 사전 공유는 역방향 의존성(`tts_server` ↔ `hook_voice`)을 만드므로 채택하지 않는다.

---

## 영문 IT 용어 개선 방안 (조사)

| 방법 | 장점 | 단점 | 채택 여부 |
|------|------|------|---------|
| LLM 리터치 | 새 용어 자동, 문맥 이해 | 지연 ~0.5s, 비용, 일관성 | **이번 구현 — 핵심** |
| 정적 사전 `_TECH_PHONETICS` | 지연 없음, 일관성 높음 | 신규 용어 수동 추가 | **병행 (1차 방어선)** |
| 규칙 기반 G2P (대문자 약어 → 글자별) | 미등록 약어 처리 | 구현 복잡도 | 향후 옵션 |
| `g2pk` 라이브러리 | 한국어 G2P 전문 | 의존성 추가, 영문 처리 별도 | 불채택 |

---

## 설정 변경 — `config.py`

```json
{
  "speechRetouch": true
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `speechRetouch` | `true` | LLM 리터치 활성화 여부 |

`Config` dataclass에 `speech_retouch: bool = True` 추가. `handle_hook` / `handle_subagent_stop`에서 `config.speech_retouch`로 분기.

---

## 수정 파일 목록

| 파일 | 변경 내용 |
|------|---------|
| `hook_voice/summarizer.py` | `retouch_for_speech` 추가, `_RETOUCH_SYSTEM` 프롬프트, `extract_summary` 버그 수정 |
| `hook_voice/hook_handlers.py` | `handle_hook`, `handle_subagent_stop`에 `retouch_for_speech` 호출 + `config.speech_retouch` 분기 |
| `hook_voice/config.py` | `speech_retouch: bool = True` 추가, `_KEY_MAP`에 `"speechRetouch"` 등록 |
| `tests/test_summarizer.py` | `retouch_for_speech` 성공·실패·폴백 테스트 추가 |

---

## 테스트 계획

- `test_retouch_removes_markdown`: `**굵은글씨**` → `굵은글씨`
- `test_retouch_converts_it_terms`: `API` → `에이피아이`
- `test_retouch_preserves_expression_tags`: `<breath>` 보존
- `test_retouch_fallback_on_llm_failure`: LLM 예외 시 `sanitize_for_speech` 결과 반환
- `test_extract_summary_sanitized`: `extract_summary` 결과에 `**` 없음 (버그 수정 검증)

---

## 비채택 대안

- **접근법 B (extract_summary 내부)**: 요약과 정제 책임 혼합으로 단일 책임 원칙 위반
- **접근법 C (speak_hook 내부)**: player.py에 LLM 의존성 발생, 모듈 순수성 훼손
