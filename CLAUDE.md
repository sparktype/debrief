# CLAUDE.md

Guidance for agents working in this repository.

## 팀 정보

**팀**: 개발생산성본부  
**오너**: 박상선 책임매니저  
**리포**: github.com/sparktype/chorus

**팀 구성 시 모델**: `claude-sonnet-4-6`(Sonnet 4.6)만 사용합니다.  
HMG 사내 AI에서 Opus는 지원되지 않으며, Agent 파라미터 `model: "sonnet"`으로 지정합니다.

## 프로젝트 개요

Chorus는 Codex·Claude Code·Grok용 **로컬 TTS 전용** macOS Apple Silicon 서비스입니다.  
단일 Swift 실행 파일 `chorus`가 모델 설치, 메뉴바 상주 daemon, MCP (`speak` · `install`), start-family hook/skill 배선, 합성을 담당합니다.

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
3. `ONBOARDING.md` — 설치·일상 사용
4. `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` — 승인 설계 (envelope speech contract는 2026-07-19로 대체)
5. `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` — 메뉴바 상주
6. `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` — MCP speak + install + Grok (승인; 상단 errata 참고)
7. `docs/superpowers/specs/2026-07-22-reflective-companion-design.md` — 관조 도우미 · lane · emotion · 도우미 음성 (P0–P2 실배)
8. `docs/archive/` — 폐기된 Python 시대 문서 (제품 진실 아님)

## 제품 경계

**포함**

- Supertonic 3 + ONNX Runtime (Swift 패키지)
- MCP `speak` (`text`, `voice`, `speed`, `volume`, 선택 `priority`/`lane`/`emotion`) + MCP `install` (`hosts`, `repair`)
- Unix domain socket + 메뉴바 `ResidentService` (LaunchAgent `com.chorus.tts`)
- CLI: `install` / `uninstall` / `menubar` / `hook` / `mcp` (사용자 mute/mode CLI 없음)
- Hooks (Claude/Codex): SessionStart, UserPromptSubmit, SubagentStart — speak 규약 context
- Skills (모든 호스트): `chorus-setup` · `chorus-install` · `chorus-speak`
- Grok: `~/.grok/config.toml` MCP + 스킬 (훅 없음); 도구 이름 `chorus__speak` · `chorus__install`
- 메뉴바: mute · 도우미 음성 · mode · 진단 · start/stop · quit
- 관조 도우미 계약: companion 기본, 침묵 허용, 감정 enum (스펙 `2026-07-22-reflective-companion-design.md`)

**제외**

- STT / Whisper / 마이크
- Chorus 측 LLM 요약·브리핑·추천
- Python / Node / FastAPI / Prometheus / DLQ
- HTML comment speech envelope / Stop·SubagentStop speech extraction
- PreToolUse / PostToolUse
- `~/.local/bin/chorus` 사용자 CLI 심볼릭 링크

## Speech 흐름 (MCP)

```text
호스트가 앱 절대 경로로 spawn
  → /Applications/Chorus.app/Contents/MacOS/chorus mcp
      → tools/call speak { text, voice, speed, volume, priority?, lane?, emotion? }
      → 검증 후 UDS enqueue (ModePolicy: mute / companionEnabled / subagent / ceiling)
      → tools/call install { hosts?, repair? }  (복구·배선)
  → 메뉴바 상주 프로세스가 합성·재생 (emotion → EmotionProsody)

Claude / Codex start hooks
  → …/chorus hook --source claude|codex
      → SessionStart / UserPromptSubmit / SubagentStart
          추가 context: 관조 도우미 규약 + silence + lane/emotion + 역할 보이스
  → Stop / SubagentStop 은 설치하지 않음

Grok
  → 훅 context 없음 → 스킬 + MCP 도구 설명이 계약
  → /mcps 로 도구 갱신
```

에이전트는 턴 종료 시 채팅 본문이 아니라 MCP tool `speak`를 **필요할 때만** 호출합니다 (한 턴에 보통 0–1회).  
Claude Code: `mcp__chorus__speak` / `mcp__chorus__install`.  
Grok: `chorus__speak` / `chorus__install` (`search_tool` / `use_tool`).  
Chorus는 요약하지 않습니다. 기본은 **관조 도우미** (`lane=companion`, voice **F1**): 관찰 + 의미 + 다음 한 걸음.  
화면 목록만 읽는 수준이면 **침묵**(도구 생략). `emotion`은 닫힌 enum이며 재생 바이어스만 줍니다.  
서브에이전트는 `priority: "subagent"`와 `lane: "work"`를 권장합니다 (focus/quiet/night에서 subagent 억제).  
본문에 speech JSON·HTML 주석을 넣지 마세요. 메뉴 **도우미 음성** off면 companion lane은 재생되지 않습니다.

설치·복구:

```bash
./scripts/with-xcode.sh swift build -c release
.build/release/chorus install --claude --repair   # 또는 --codex / --grok / 플래그 없이 전체
```

MCP가 이미 되면 `install` 도구로 repair 가능합니다. Hook·MCP command는 HostInstaller가 **앱 절대 경로**로 merge합니다.

전송 실패·합성 실패는 `~/Library/Caches/Chorus/last-error.json`에 기록되며 메뉴바 **진단**에 표시됩니다. 에이전트 완료는 막지 않습니다.

## 구현 규칙

1. 동작 변경 전 실패 테스트 먼저 (TDD).
2. Python·shell 런타임 래퍼를 다시 넣지 않습니다.
3. 사용자 노출 문자열은 경어체를 유지합니다.
4. 완료 주장은 `./scripts/with-xcode.sh swift test`와 release 빌드 성공 이후에만.
