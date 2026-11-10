# 하드닝 컨텍스트 노트

## 2026-11-10 시작
- 브랜치 `chore/hardening-2026-11`. 사용자가 추천 6개 전부 진행을 승인.
- 근거: basic-memory `Projects/debrief 상태.md`(소켓 소실 사고 10-19·10-27, 리뷰 Minor 9건 미수정, Supertonic 미러 결정).
- HF 미러 `codeguru76/supertonic-3` 공개 확인, 전체 리비전 `f26b6b0ac3583e5fc3706cb21d70c3c6cfc3f316`.

## 1. 소켓 이전
- 새 경로 `Application Support/debrief/debrief.sock`. `permissions_directory`가 이미 같은 이유로 데이터 디렉터리에 있어 같은 판단을 적용.
- 장수 MCP 프로세스(호스트 세션 동안 유지)는 옛 경로가 컴파일돼 있어, 업그레이드 직후 새 데몬에 못 닿는다 → 옛 경로에 심볼릭 링크(데몬 실행 중에만). 일반 파일·디렉터리는 지우지 않는다.
- pid·last-error.json은 아직 Caches. 소실 사고는 소켓만 기록돼 이번엔 두지 않음(후속 후보).
