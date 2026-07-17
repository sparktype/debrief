# CLAUDE.md

Guidance for agents working in this repository.

## 팀 정보

**팀**: 개발생산성본부  
**오너**: 박상선 책임매니저  
**리포**: github.com/sparktype/chorus

**팀 구성 시 모델**: `claude-sonnet-4-6`(Sonnet 4.6)만 사용합니다.  
HMG 사내 AI에서 Opus는 지원되지 않으며, Agent 파라미터 `model: "sonnet"`으로 지정합니다.

## 프로젝트 개요

Chorus는 Codex·Claude Code용 **로컬 TTS 전용** macOS Apple Silicon 서비스입니다.  
단일 Swift 실행 파일 `chorus`가 모델 설치, 메뉴바 상주 daemon, hook/skill 배선, 합성을 담당합니다.

**Python 런타임은 제거되었습니다.** `hook_voice`, `tts_server`, pytest, FastAPI, Whisper, LLM 요약을 재도입하지 마세요.

## 툴체인 (필수)

**Xcode 27 beta**를 기준으로 빌드·테스트합니다. Command Line Tools만 있으면 Swift Testing 매크로가 실패합니다.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
# 또는
./scripts/with-xcode.sh swift test
./scripts/with-xcode.sh swift build -c release
```

| 항목 | 값 |
|------|-----|
| App | `/Applications/Xcode-beta.app` |
| Build (검증됨) | Xcode 27.0 / 27A5218g |
| Swift | 6.4 |
| 플랫폼 | macOS 14+, arm64 |

`.envrc`가 `DEVELOPER_DIR`을 설정합니다. 시스템 전역 전환이 필요하면:

```bash
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

## 규범 문서

1. `README.md` — 사용자 진입점
2. `DEVELOPER.md` — 개발·빌드·범위
3. `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` — 승인 설계
4. `docs/superpowers/plans/2026-07-15-swift-single-binary-tts.md` — 구현 플랜
5. `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` — 메뉴바 상주

## 제품 경계

**포함**

- Supertonic 3 + ONNX Runtime (Swift 패키지)
- 에이전트 speech envelope 검증 (`v`, `text`, `voice`, `speed`, `volume`)
- Unix domain socket + 메뉴바 `ResidentService` (LaunchAgent `com.chorus.tts`)
- `install` / `uninstall` / `menubar` / `hook`
- Hooks: SessionStart, UserPromptSubmit, SubagentStart, Stop, SubagentStop
- 메뉴바: mute · mode · start/stop · quit (사용자 CLI 없음)

**제외**

- STT / Whisper / 마이크
- Chorus 측 LLM 요약·브리핑·추천
- Python / Node / FastAPI / Prometheus / DLQ
- PreToolUse / PostToolUse
- `~/.local/bin/chorus` 사용자 CLI 심볼릭 링크

## Claude / Codex hook 흐름

```text
Claude lifecycle JSON (stdin)
  → /Applications/Chorus.app/Contents/MacOS/chorus hook --source claude
      → SessionStart / UserPromptSubmit / SubagentStart
          추가 context: chorus:speak envelope 규약 + 역할 보이스
      → Stop / SubagentStop
          last_assistant_message 에서 envelope 추출 → UDS enqueue
  → 메뉴바 상주 프로세스가 합성·재생
```

에이전트는 최종 응답 끝에 정확히 한 줄의

```text
<!-- chorus:speak {"v":1,"text":"한두 문장 요약","voice":"F1","speed":0.93,"volume":0.85} -->
```

를 붙입니다. Chorus는 요약하지 않습니다. `voice`는 역할 배정과 일치해야 합니다 (메인 기본 F1).

설치:

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude   # 또는 플래그 없이 양 호스트
```

Hook command는 HostInstaller가 **앱 절대 경로**로 merge합니다. PATH의 `chorus`에 의존하지 않습니다.

전송 실패·보이스 불일치는 `~/Library/Caches/Chorus/last-error.json`에 기록되며 메뉴바 오류 줄에 표시됩니다. 에이전트 완료(stdout `{}`)는 막지 않습니다.

## 구현 규칙

1. 동작 변경 전 실패 테스트 먼저 (TDD).
2. Python·shell 런타임 래퍼를 다시 넣지 않습니다.
3. 사용자 노출 문자열은 경어체를 유지합니다.
4. 완료 주장은 `./scripts/with-xcode.sh swift test`와 release 빌드 성공 이후에만.
