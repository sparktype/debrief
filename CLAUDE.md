# CLAUDE.md

Guidance for agents working in this repository.

## 팀 정보

**팀**: 개발생산성본부  
**오너**: 박상선 책임매니저  
**리포**: github.com/sparktype/debrief

**팀 구성 시 모델**: `claude-sonnet-4-6`(Sonnet 4.6)만 사용합니다.  
HMG 사내 AI에서 Opus는 지원되지 않으며, Agent 파라미터 `model: "sonnet"`으로 지정합니다.

## 프로젝트 개요

debrief는 Codex·Claude Code·Grok용 **로컬 TTS 전용** macOS Apple Silicon 서비스입니다.  
단일 Rust 실행 파일 `debrief`가 모델 설치, 헤드리스 LaunchAgent, MCP (`speak` · `install`), start-family hook/skill 배선, 합성을 담당합니다.

**Python 런타임은 제거되었습니다.** `hook_voice`, `tts_server`, pytest, FastAPI, Whisper, LLM 요약을 재도입하지 마세요.  
**Swift 소스는 포팅 전 참고용으로만 리포에 남아 있습니다** (`Sources/`, `SwiftTests/`, `Package.swift`). CI는 빌드·테스트하지 않으며 제품 진실이 아닙니다. 재도입하지 마세요.

## 툴체인 (필수)

Rust 툴체인(`rustup`)으로 빌드·테스트합니다.

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo build --release
```

| 항목 | 값 |
|------|-----|
| 워크스페이스 | `debrief-core`(lib) · `debrief-tts`(lib) · `debrief`(bin) |
| 플랫폼 | macOS 14+, arm64 |
| 버전 | `DebriefVersion::CURRENT` = `0.1.3` (`CARGO_PKG_VERSION`, 태그 `v0.1.3`) |
| 사용자 설치 | `brew install sparktype/tap/debrief` 다음 `debrief install` (Homebrew가 GitHub Release의 프리빌트 바이너리를 받음, 소스 빌드 불필요). 소스 빌드는 `cargo build --release` |

## 규범 문서

1. `README.md` — 사용자 진입점
2. `DEVELOPER.md` — 개발·빌드·범위
3. `ONBOARDING.md` — 설치·일상 사용
4. `docs/superpowers/specs/2026-07-15-swift-single-binary-tts-design.md` — 승인 설계 (envelope speech contract는 2026-07-19로 대체, 전체 구현은 Rust 재작성으로 대체)
5. `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md` — 이전 메뉴바 상주 (패키징은 2026-09-29 데몬 스펙으로 대체)
5a. `docs/superpowers/specs/2026-09-29-daemon-single-binary-design.md` — 헤드리스 데몬 · CLI (구현됨. 본문 식별자는 chorus)
6. `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` — MCP speak + install + Grok (승인; 상단 errata 참고)
7. `docs/superpowers/specs/2026-07-22-reflective-companion-design.md` — lane · emotion · 도우미 음성 (태도·타이밍은 2026-09-29 턴 브리핑으로 대체)
8. `docs/superpowers/specs/2026-09-30-rust-rewrite-design.md` — Rust 재작성: 크레이트 경계, 동기 동시성 모델, 배포 파이프라인
9. `docs/archive/` — 폐기된 Python 시대 문서 (제품 진실 아님)

## 제품 경계

**포함**

- Supertonic 3 + ONNX Runtime (`ort` crate) + 오디오 재생 (`cpal`)
- MCP `speak` (`text`, `voice`, `speed`, `volume`, 선택 `priority`/`lane`/`emotion`/`session`) + MCP `install` (`hosts`, `repair`)
- Unix domain socket + `debrief daemon`의 `ResidentService` (LaunchAgent `com.debrief.tts`, `gui/<uid>`)
- CLI: `install` / `uninstall` / `daemon` / `start` / `stop` / `status` / `doctor` / `mute` / `mode` / `companion` / `dnd` / `hook` / `mcp` (`speak` CLI 없음)
- Hooks (Claude/Codex): SessionStart, UserPromptSubmit, SubagentStart — speak 규약 context. PermissionRequest · Stop — 고정 문구 알림(아래). SessionEnd — 세션 상태 정리. Claude 전용 StopFailure · Notification · Elicitation · PermissionDenied · TeammateIdle · TaskCompleted — 고정 문구 알림. 설계는 `docs/superpowers/specs/2026-10-04-hook-notices-design.md`
- 훅 알림(에이전트가 말할 수 없는 순간): 권한 요청, API 오류로 중단(StopFailure), 입력 대기(Notification idle_prompt·agent_needs_input / Elicitation), 자동 모드 거부(PermissionDenied), 에이전트가 말하지 않은 `longTurnSeconds`(기본 60) 이상 턴의 완료. 팀 이벤트(TeammateIdle·TaskCompleted)는 `teamNotices`를 켠 경우만. 잦은 유형은 쿨다운(2~5분). LLM 생성 없는 고정 문구(`lane=work`)이며 `mute`로만 꺼집니다
- 멀티 세션: 다른 프로젝트 세션이 30분 안에 활성이면 speak 앞에 `"<프로젝트>. "`를 붙입니다(`sessionLabel`, 기본 켜짐)
- 방해금지 연동(옵트인 `debrief dnd on`): macOS 방해금지가 켜지면 유효 모드를 최소 quiet로 올립니다(저장된 모드는 그대로, night은 유지). `debrief doctor`의 `dnd.readable`로 판독 여부 확인. `doctor`는 호스트별 훅 이벤트 누락도 `hooks.<host>.missing`으로 알려 줍니다
- Skills (모든 호스트): `debrief-setup` · `debrief-install` · `debrief-speak`
- Grok: `~/.grok/config.toml` MCP + 스킬 (훅 없음); 도구 이름 `debrief__speak` · `debrief__install`
- 제어: `debrief mute` · `debrief companion` · `debrief mode` · `debrief doctor` · `debrief start` · `debrief stop`
- 턴 브리핑 계약: 사용자에게 보이는 턴마다 바뀐 점 + 다음 행동 한 줄 (`lane=companion`). 도우미 목소리는 세션마다 F1–M5를 돌고, 같은 `session`은 같은 목소리를 유지합니다. 코드를 개발·분석한 턴의 다음 행동은 사용자가 직접 확인할 핵심(동작 변경·삭제·보안/데이터 경로·에이전트의 가정·확인/되돌리기 방법)으로 삼아 코드 오너십을 지키고 인지 부채를 줄입니다(서브에이전트·사소한 변경 제외). 새 사실도 다음 행동도 없을 때만 침묵. lane·emotion은 `2026-07-22-reflective-companion-design.md`
- `decide`(로컬 판단 모델, `jev-style serve` `http://127.0.0.1:8765`) 선택적 연동 — 텍스트를 생성하지 않고 확률/선택만 반환하는 보강 전용. `DebriefConfiguration.decideEnabled`/`decideEndpoint`로 토글(기본 활성화). `decide` 불가·타임아웃·연결 끊김 시 전부 기존 동작으로 즉시 폴백(fail-open). 적용 지점:
  - 미등록 `agent_type` 역할 분류 (`voice_catalog.rs::assignment_with_decide`) — 정적 매핑에 없을 때만 호출
  - MCP `speak`(`mcp_speak_tool.rs::execute_with_decide`): main+companion 브리핑의 침묵 판단, `emotion: "auto"` 선택, subagent→main priority 승격
  - `debrief doctor`(`diagnostics.rs::doctor_report_text_with_decide`): `decide.reachable` 상태 + 참고용 모드 추천(자동 적용 없음, `debrief mode`는 사용자가 직접)

**제외**

- STT / Whisper / 마이크
- debrief 자체 텍스트 생성(LLM 호출)에 의한 요약·브리핑·추천. 단, 위 `decide` 연동(확률/선택만 반환, 텍스트 생성 없음, fail-open)은 예외로 허용
- Python / Node / FastAPI / Prometheus / DLQ
- HTML comment speech envelope / Stop·SubagentStop speech extraction
- PreToolUse / PostToolUse
- `debrief speak` CLI와 메뉴바 앱. 설치 목적지는 `~/.local/bin/debrief`입니다.

## Speech 흐름 (MCP)

```text
호스트가 ~/.local/bin/debrief 절대 경로로 spawn
  → debrief mcp
      → tools/call speak { text, voice, speed, volume, priority?, lane?, emotion?, session? }
      → 검증 후 UDS enqueue (ModePolicy: mute / companionEnabled / subagent / ceiling)
      → tools/call install { hosts?, repair? }  (복구·배선)
  → debrief daemon이 합성·재생 (emotion → EmotionProsody)

Claude / Codex start hooks
  → …/debrief hook --source claude|codex
      → SessionStart / UserPromptSubmit / SubagentStart
          추가 context: 턴 브리핑(what changed, next action; 코드 작업 후엔 ownership 확인) + Silence only + lane/emotion + 역할 보이스
  → PermissionRequest / Stop(+ Claude 전용 알림 이벤트) 훅은 데몬에 고정 문구 알림만 직접 보냄 (Stop에서 문장 추출은 하지 않음)
  → SessionEnd 는 세션 상태만 지움
  → SubagentStop 은 설치하지 않음

Grok
  → 훅 context 없음 → 스킬 + MCP 도구 설명이 계약
  → /mcps 로 도구 갱신
```

에이전트는 사용자에게 보이는 턴이 끝나면 MCP tool `speak`를 **한 번** 호출합니다 (한 턴에 0–1회).  
두 문장, 사용자 언어: 무엇이 바뀌었는지, 다음에 할 행동 하나(또는 기다림). 문장은 에이전트가 씁니다.  
새 사실도 다음 행동도 없으면 도구를 생략합니다 (Silence only).  
Claude Code: `mcp__debrief__speak` / `mcp__debrief__install`.  
Grok: `debrief__speak` / `debrief__install` (`search_tool` / `use_tool`).  
기본 lane은 `companion`, speed ~0.93, volume ~0.85. 도우미 목소리는 세션마다 F1–M5를 돌고, `session`이 같으면 그 목소리를 유지합니다. `session`이 없으면 이 MCP 프로세스가 받은 목소리를 씁니다. `emotion`은 닫힌 enum이며 재생 바이어스만 줍니다.  
서브에이전트는 사용자에게 브리핑하지 않지만, 작업이 끝나면 한 번 `priority: "subagent"`, `lane: "work"`, 사실 한 줄로 말합니다 (focus/quiet/night에서 subagent 억제).  
본문에 speech JSON·HTML 주석을 넣지 마세요. `debrief companion off`면 companion lane은 재생되지 않습니다.

설치·복구:

```bash
cargo build --release
./target/release/debrief install --repair   # 또는 --claude / --codex / --grok
```

MCP가 이미 되면 `install` 도구로 repair 가능합니다. Hook·MCP command는 HostInstaller가 `~/.local/bin/debrief` 절대 경로로 merge합니다.

전송 실패·합성 실패는 `~/Library/Caches/debrief/last-error.json`에 기록되며 `debrief doctor`에 표시됩니다. 에이전트 완료는 막지 않습니다.

## 구현 규칙

1. 동작 변경 전 실패 테스트 먼저 (TDD).
2. Python·shell 런타임 래퍼를 다시 넣지 않습니다.
3. 사용자 노출 문자열은 경어체를 유지합니다.
4. 완료 주장은 `cargo test --workspace`, `cargo clippy --workspace --all-targets`와 release 빌드 성공 이후에만.
