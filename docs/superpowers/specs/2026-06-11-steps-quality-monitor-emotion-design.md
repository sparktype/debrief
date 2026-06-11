# Steps 품질 향상 + Monitor 감정 표현 설계

**날짜**: 2026-06-11  
**상태**: 승인됨

## 요약

두 가지 개선을 동시에 적용한다.

1. **Steps 전반 상향**: 영문·숫자·한글 혼합 발화 품질 개선을 위해 모든 목소리의 diffusion steps를 품질 우선(12~14)으로 상향
2. **Monitor 감정 표현**: Monitor 모드 발화에 `select_expression_tag("reviewer")` 적용 — 모니터링 결과의 좋음/나쁨/보통을 태그로 표현

## Part 1: Steps 상향

### 변경 파일

| 파일 | 변경 |
|------|------|
| `voice-map.json` | `voice_settings` 각 Voice의 steps 상향 |
| `hook_voice/player.py` | `HOOK_STEPS = 8` → `12` |

### Steps 변경 값

| Voice | 역할 | 현재 | 변경 후 |
|-------|------|------|--------|
| F1 | 연아 (메인) | 8 | 12 |
| F2 | 마리 | 8 | 12 |
| F3 | 제인 | 10 | 14 |
| F4 | 셰릴 | 9 | 12 |
| F5 | 리사 | 8 | 12 |
| M1 | 스티브 | 8 | 12 |
| M2 | 빌 (Monitor) | 10 | 14 |
| M3 | 일론 | 9 | 12 |
| M4 | 리누스 | 8 | 12 |
| M5 | 팀 | 9 | 12 |
| HOOK_STEPS (speak_hook) | — | 8 | 12 |

## Part 2: Monitor 감정 표현

### 변경 파일

| 파일 | 변경 |
|------|------|
| `hook_voice/hook_handlers.py` | `handle_hook()` Monitor 모드에 태그 적용 |

### 로직

```
Monitor 모드 발화 시:
  summary = extract_summary(text)
  tag = select_expression_tag(summary, "reviewer")
  speak_text = f"{tag} {summary}"  ← 기존: summary만
  speak_agent(speak_text, "M2", ...)
```

### 태그 선택 규칙 (`select_expression_tag("reviewer")` 적용)

| 모니터링 결과 | 매칭 키워드 | 태그 |
|-------------|-----------|------|
| 치명 장애·다운 | 치명, 장애, 다운 | `<cry>` |
| 예상치 못한 급변 | 예상치 못, 의외, 갑자기 | `<gasp>` |
| 경고·주의 | 주의, 경고, 위험 | `<clear_throat>` |
| 아쉬움·미완성 | 아쉽, 미완성, 개선 필요 | `<sniff>` |
| 오류·에러 | 실패, 에러, 오류, 문제 | `<sigh>` |
| 발견·흥미 | 발견, 분석, 흥미 | `<hmm>` |
| 정상·이상없음 | 정상, 이상없음 | `<breath>` (reviewer 기본) |
| 일반 | — | `<breath>` |

### 불변 조건

- `select_expression_tag`는 기존 함수를 그대로 사용 (수정 없음)
- `handle_subagent_stop`의 감정 태그 로직과 동일한 패턴 — 일관성 유지
- tag가 빈 문자열인 경우 prepend 없이 summary만 사용 (방어적 처리)
