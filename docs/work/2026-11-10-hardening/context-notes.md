# 하드닝 컨텍스트 노트

## 2026-11-10 시작
- 브랜치 `chore/hardening-2026-11`. 사용자가 추천 6개 전부 진행을 승인.
- 근거: basic-memory `Projects/debrief 상태.md`(소켓 소실 사고 10-19·10-27, 리뷰 Minor 9건 미수정, Supertonic 미러 결정).
- HF 미러 `codeguru76/supertonic-3` 공개 확인, 전체 리비전 `f26b6b0ac3583e5fc3706cb21d70c3c6cfc3f316`.

## 1. 소켓 이전
- 새 경로 `Application Support/debrief/debrief.sock`. `permissions_directory`가 이미 같은 이유로 데이터 디렉터리에 있어 같은 판단을 적용.
- 장수 MCP 프로세스(호스트 세션 동안 유지)는 옛 경로가 컴파일돼 있어, 업그레이드 직후 새 데몬에 못 닿는다 → 옛 경로에 심볼릭 링크(데몬 실행 중에만). 일반 파일·디렉터리는 지우지 않는다.
- pid·last-error.json은 아직 Caches. 소실 사고는 소켓만 기록돼 이번엔 두지 않음(후속 후보).

## 2. 재생 대기
- 기존: 오류 콜백이 비어 있고 Condvar를 무기한 대기 → 재생 중 장치가 끊기면 합성·재생 루프가 묶임.
- cpal 0.18 `ErrorKind` 중 DeviceNotAvailable·StreamInvalidated·HostUnavailable만 치명으로 본다. DeviceChanged는 cpal이 기본 장치로 스트림을 옮기니 계속 재생.
- 오류 없이 조용히 멈추는 경우를 위해 클립 길이 + 3초 상한. 실패는 기존 AudioPlayer의 rebuild 후 1회 재시도 경로를 탄다.
- 실장치 분리 재현은 하지 못함. 대기 로직만 단위 테스트(하드웨어 없이).
