# Chorus 플러그인 마이그레이션

## 변경점

기존 설치는 저장소 절대 경로와 여러 hook shell에 의존했습니다. 플러그인 설치는 불변 릴리스를 `~/.local/share/chorus/runtime/releases`에 두고 `runtime/current`를 통해 실행합니다. LaunchAgent는 `io.chorus.server` 하나만 사용합니다.

## 마이그레이션 순서

1. Claude Code 또는 Codex에 `chorus` 플러그인을 설치합니다.
2. `/chorus:setup`을 실행합니다.
3. 기존 `.voice.json` 가져오기 결과와 선택한 개인정보 프리셋을 확인합니다.
4. Codex에서는 `/hooks`에서 새 hook을 신뢰합니다.
5. `/chorus:status`로 새 제공자의 hook delivery를 확인합니다.
6. 새 daemon health가 정상인 경우에만 기존 `com.voice-persona.tts-server` LaunchAgent를 제거합니다.

기존 파일에서 `autoSpeak`, `usageTracking`, `assistantTts.enabled`가 꺼져 있으면 상세 프리셋을 선택해도 마이그레이션이 이를 다시 켜지 않습니다.

## 호환 명령

`setup-tts.sh`, `server.sh`, `install.sh`, `uninstall.sh`는 deprecated 안내 후 `chorus-runtime`으로 위임합니다. 저장소 hook들도 짧은 fail-open 전달 래퍼로 남아 있으므로 전환 중 에이전트 작업을 막지 않습니다.

## 제거와 데이터

일반 `chorus-runtime uninstall`은 runtime 등록을 제거하되 `config.json`, 상태, 통계, 모델, 로그를 보존합니다. 사용자가 명시적으로 `chorus-runtime uninstall --purge`를 실행할 때만 `~/.local/share/chorus` 전체를 삭제합니다.

문제가 있으면 `/chorus:doctor`를 실행하세요. 각 실패는 한 개의 정확한 복구 명령을 제공합니다.
