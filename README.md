# Chorus

Chorus는 Claude Code와 Codex의 작업 결과를 로컬 음성으로 전달하는 macOS Apple Silicon용 플러그인입니다. 설치 전과 설정 전에는 자동 발화, 사용 통계, 외부 LLM 전송이 모두 꺼져 있습니다.

## 요구 사항

- Apple Silicon Mac과 macOS
- Claude Code 또는 Codex
- Python 3.11 이상
- 음성 입력을 사용할 때만 마이크 권한

## 플러그인 설치

이 저장소는 하나의 `plugins/chorus` 패키지와 두 marketplace 진입점을 제공합니다.

### Claude Code

Claude Code의 plugin marketplace에 이 저장소를 추가하고 `chorus`를 설치합니다. 설치가 끝나면 다음을 실행합니다.

```text
/chorus:setup
```

### Codex

Codex에서 이 저장소의 `.agents/plugins/marketplace.json`을 통해 `chorus` 플러그인을 설치합니다. 설치 후 `/hooks`를 열어 Chorus hook을 검토하고 신뢰한 다음 실행합니다.

```text
/chorus:setup
```

설정은 플랫폼 확인, 안정 런타임 설치, 단일 `io.chorus.server` LaunchAgent 등록, 개인정보 프리셋 선택, hook 확인, 음성 테스트 순으로 진행됩니다. 소스 저장소를 이동하거나 삭제해도 설치된 런타임은 `~/.local/share/chorus/runtime/current`에서 계속 동작합니다.

## 개인정보 프리셋

설정 전 기본값은 `configured=false`, `autoSpeak=false`, `usageTracking=false`, `externalLlm=false`입니다.

| 프리셋 | 자동 발화 | 외부 LLM | 사용 통계 | 도구 이벤트 |
| --- | --- | --- | --- | --- |
| `local` | 음성 테스트 후 켬 | 끔 | 끔 | 로컬 규칙 기반 실패만 |
| `standard` | 음성 테스트 후 켬 | Stop 요약만 | 끔 | 실패만 |
| `detailed` | 음성 테스트 후 켬 | 요약·실패 설명·프롬프트 도움 | 켬 | 빌드·테스트·위험·실패 |

`standard` 또는 `detailed`을 선택하기 전에 설정 화면이 전송 대상 텍스트와 endpoint를 보여줍니다. 선택적 외부 자격 증명이 없으면 로컬 규칙 기반 처리로 축소됩니다.

## 공통 명령

Claude Code와 Codex에서 동일한 명령을 사용합니다.

| 명령 | 용도 |
| --- | --- |
| `/chorus:setup` | 설치, 마이그레이션, 개인정보 프리셋, 음성 테스트 |
| `/chorus:status` | 런타임, hook, 개인정보, 큐, 음소거, 최근 오류 |
| `/chorus:doctor` | 전체 진단과 정확한 복구 명령 |
| `/chorus:mute` | 전역·세션·30분 음소거 또는 해제 |
| `/chorus:listen` | STT 토글과 마이크/모델 오류 안내 |
| `/chorus:mode` | `normal`, `focus`, `quiet`, `verbose`, `night` |
| `/chorus:digest` | 최근 hook·발화·오류 메타데이터 |

Codex에서 hook 기록이 없다면 먼저 `/hooks` 신뢰 상태를 확인하세요. 서비스가 조용하거나 상태가 불명확하면 `/chorus:status`, 이어서 `/chorus:doctor`를 사용합니다.

## 데이터와 업데이트

```text
~/.local/share/chorus/
├── runtime/releases/<version>/
├── runtime/current -> releases/<version>
├── config.json
├── state.json
├── usage_stats.jsonl
└── logs/
```

업데이트는 새 릴리스를 staging하고 Python 소스를 검증한 뒤 `current` 링크를 원자적으로 전환합니다. 실패하면 이전 릴리스가 유지되며 설정·상태·통계·로그는 릴리스 외부에 보존됩니다.

## 레거시 저장소 스크립트

`setup-tts.sh`, `server.sh`, `install.sh`, `uninstall.sh`는 한 릴리스 동안 호환 래퍼로 유지되지만 새 설치에는 플러그인을 사용하세요. 기존 `.voice.json`은 최초 설정에서 한 번 가져오며, 꺼져 있던 기능을 다시 켜지 않습니다. 자세한 내용은 [플러그인 마이그레이션](docs/plugin-migration.md)을 참고하세요.

개발 및 테스트 구조는 [DEVELOPER.md](DEVELOPER.md), 구현 설계는 [Cross-Agent Plugin Design](docs/superpowers/specs/2026-07-14-chorus-cross-agent-plugin-design.md)을 참고하세요.
