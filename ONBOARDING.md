# Chorus 온보딩

Chorus는 Claude Code와 Codex에서 같은 `/chorus:*` 명령과 같은 로컬 음성 런타임을 사용합니다.

## 안전한 시작 상태

플러그인 설치만으로는 음성이나 외부 통신이 시작되지 않습니다.

- `configured=false`
- `autoSpeak=false`
- `usageTracking=false`
- `externalLlm=false`

## 시작 체크리스트

- [ ] Claude Code 또는 Codex에 이 저장소의 `chorus` 플러그인을 설치합니다.
- [ ] Codex에서는 `/hooks`에서 Chorus hook을 검토하고 신뢰합니다.
- [ ] `/chorus:setup`을 실행하고 `local`, `standard`, `detailed` 중 하나를 선택합니다.
- [ ] 개인정보 요약과 외부 endpoint를 확인합니다.
- [ ] 음성 테스트 후 `/chorus:status`에서 runtime과 hook delivery를 확인합니다.
- [ ] 실패 항목이 있으면 `/chorus:doctor`가 제시하는 복구 명령을 실행합니다.

외부 전송이 필요하지 않다면 `local`을 선택하세요. `standard`는 Stop 요약만, `detailed`은 추가 도움 기능과 사용 통계를 명시적으로 활성화합니다.

## 일상 사용

- 집중이 필요하면 `/chorus:mode focus` 또는 `/chorus:mode quiet`
- 잠시 멈추려면 `/chorus:mute 30m`
- 음성 입력은 `/chorus:listen`
- 최근 이벤트는 `/chorus:digest`
- 이상 상태는 `/chorus:status` 후 `/chorus:doctor`

사용자 데이터는 `~/.local/share/chorus`에 있고 일반 제거 시 보존됩니다. 완전 삭제가 필요한 경우에만 `chorus-runtime uninstall --purge`를 사용합니다.
