# debrief

![debrief. 에이전트가 고른 문장을 이 Mac에서 읽습니다. Codex, Claude Code, Grok이 speak로 넘기면 로컬 데몬이 Supertonic 3으로 재생합니다.](docs/images/banner.png)

Apple Silicon Mac에서 Codex, Claude Code, Grok이 고른 문장을 로컬에서 읽어 주는 TTS입니다. 실행 파일 하나가 `LaunchAgent`로 상주하고, 에이전트는 MCP `speak`로만 말합니다.

저장소: [github.com/sparktype/debrief](https://github.com/sparktype/debrief)

## 하는 일

호스트가 `~/.local/bin/debrief mcp`를 짧게 띄웁니다. `speak`는 문장을 검사한 뒤 Unix 소켓으로 넘기고, 상주 프로세스 `debrief daemon`이 Supertonic 3으로 합성해 현재 GUI 세션에서 재생합니다. Claude와 Codex는 시작 훅으로 말하기 규약을 받고, Grok은 스킬과 MCP 도구 설명이 그 규약입니다.

포함되는 것:

- 헤드리스 데몬과 CLI (`status`, `doctor`, `mute`, `mode`, `companion`, `start`, `stop`)
- MCP `speak`, `install`
- Claude / Codex 시작 훅 (SessionStart, UserPromptSubmit, SubagentStart)과 세 호스트용 스킬

범위 밖:

- 음성 인식, 마이크, debrief 쪽 요약
- `debrief speak` 명령, 메뉴바 앱, Stop 훅에서 문장을 뽑는 방식

## 요구 사항

- Apple Silicon, macOS 14 이상
- Codex, Claude Code, Grok 중 하나 이상
- 소스 설치에는 Rust 툴체인(`rustup`)

버전은 `0.1.0`입니다. 설치는 Homebrew 포뮬러 `sparktype/tap/debrief`입니다.

## 설치

```sh
brew install sparktype/tap/debrief
debrief install
```

소스에서 빌드할 때는 Rust 툴체인이 필요합니다.

```sh
git clone https://github.com/sparktype/debrief.git
cd debrief
cargo build --release
env -u HF_HUB_OFFLINE ./target/release/debrief install
```

셸에서 `debrief`를 찾으려면 `~/.local/bin`이 `PATH`에 있어야 합니다. LaunchAgent는 절대 경로로 데몬을 띄우므로, 경로가 없어도 재생 자체는 됩니다.

```sh
export PATH="$HOME/.local/bin:$PATH"
debrief status
```

`HF_HUB_OFFLINE`이 켜져 있으면 모델 다운로드 전에 해제합니다. 이미 검증된 모델이 있으면 `debrief install --repair`로 다시 받지 않습니다. 설치가 끝나면 `debrief doctor`로 확인합니다.

`debrief install`은 다음 순서로 진행합니다.

1. 실행 파일을 `~/.local/bin/debrief`에 복사합니다 (원자적 교체, 모드 `0755`). 그 경로가 디렉터리면 설치를 멈추고 지우지 않습니다.
2. Supertonic 3을 `~/Library/Application Support/debrief/models/`에 두고 체크섬을 확인합니다.
3. 선택한 호스트에 MCP, 스킬, Claude/Codex 시작 훅을 절대 경로로 넣습니다.
4. `~/Library/LaunchAgents/com.debrief.tts.plist`를 쓰고 `debrief daemon`을 부트스트랩합니다.

호스트를 제한하려면 `--codex`, `--claude`, `--grok`를 조합합니다. 플래그가 없으면 세 호스트 모두입니다. `--repair`는 소유한 파일을 다시 맞추고, 사용자가 고친 파일은 다이제스트가 다르면 덮어쓰지 않습니다.

| 호스트 | 설치 후 |
| --- | --- |
| Claude Code | `~/.claude.json`의 `mcpServers["debrief"]`. 스킬은 `~/.claude/skills`. Claude를 재시작하면 `mcp__debrief__speak`, `mcp__debrief__install`이 보입니다. |
| Codex | MCP는 `~/.codex/config.toml`. 훅은 `~/.codex/hooks.json`. `/hooks`에서 훅을 신뢰합니다. 스킬은 `~/.agents/skills`. |
| Grok | MCP는 `~/.grok/config.toml`의 `[mcp_servers.debrief]`. 훅은 없습니다. `/mcps`로 `debrief__speak`, `debrief__install`을 갱신합니다. 스킬은 `~/.grok/skills`. |

로그인하면 LaunchAgent가 `debrief daemon`을 띄웁니다. 오디오는 GUI 세션에서 재생됩니다.

## 명령

인자 없이 실행하면 사용법이 표준 출력으로 나오고 종료 코드는 0입니다. 알 수 없는 명령은 표준 에러와 종료 코드 64입니다.

```sh
debrief help
debrief status
debrief doctor
debrief mute [on|off|toggle]
debrief mode [normal|focus|quiet|verbose|night]
debrief companion [on|off|toggle]
debrief start
debrief stop
debrief uninstall [--codex] [--claude] [--grok]
```

`debrief status`는 데몬이 내려가 있어도 종료 코드 0입니다.

```text
프로세스: 실행 중
음소거: 꺼짐
모드: normal
도우미 음성: 켜짐
모델: <revision>
소켓: 있음
LaunchAgent: 설치됨
```

음소거가 켜지면 `음소거: 켜짐`입니다. 모델을 쓸 수 없으면 `revision (사용할 수 없음)`입니다.

| 명령 | 동작 |
| --- | --- |
| `debrief mute` | 인자가 없으면 토글합니다. `on` / `off`는 지정입니다. 다음 발화부터 적용됩니다. |
| `debrief mode` | 인자가 없으면 `현재 모드는 <mode>입니다.` 값이 있으면 `모드를 <mode>로 설정했습니다.` |
| `debrief companion` | 도우미 음성(companion lane)을 켜거나 끕니다. 꺼도 work lane은 음소거가 아니면 재생됩니다. |
| `debrief doctor` | 진단입니다. 정상이 아닌 항목이 있으면 종료 코드 1입니다. |
| `debrief start` | 있는 plist만 부트스트랩합니다. plist가 없으면 `debrief install`을 안내하고 종료 코드 1입니다. 이미 실행 중이면 프로세스를 바꾸지 않습니다. |
| `debrief stop` | 에이전트를 끄고 bootout 합니다. 실행 파일과 plist는 남습니다. |
| `debrief uninstall` | 배선을 제거하고, 다이제스트가 설치 기록과 같은 실행 파일만 지웁니다. |

### 모드

| 모드 | 효과 |
| --- | --- |
| `normal` | 기본. main과 subagent를 재생합니다. 볼륨 상한 1.0 |
| `focus` | `priority=subagent`를 재생하지 않습니다 |
| `quiet` | 볼륨 상한 0.45. subagent를 재생하지 않습니다 |
| `verbose` | subagent를 포함합니다. 볼륨 상한 1.0 |
| `night` | 볼륨 상한 0.20. subagent를 재생하지 않습니다 |

### 진단이 안내하는 복구

처음 맞는 한 줄만 따릅니다.

| 상태 | 복구 |
| --- | --- |
| plist가 없거나 모델이 없거나 손상됨 | `debrief install --repair` |
| 프로세스는 있는데 소켓이 없음 | `debrief install --repair` |
| plist는 있는데 프로세스가 없음 | `debrief start` |

모델이 없으면 데몬은 `last-error.json`만 남기고 소켓을 열지 않은 채 대기합니다. 이때 `debrief start`는 이미 실행 중이라 프로세스를 바꾸지 않습니다. 모델을 둔 뒤 `debrief install --repair`로 교체합니다.

전송이나 합성 실패는 `~/Library/Caches/debrief/last-error.json`에 기록되고 `debrief doctor`에 나옵니다. 에이전트 턴은 막지 않습니다.

## 설정

재생 정책은 `~/Library/Application Support/debrief/config.json`입니다. 데몬은 발화마다 이 파일을 다시 읽으므로 재시작이 필요 없습니다. 바꾸는 방법은 CLI입니다. 잘못된 값은 파일을 쓰기 전에 거절되고, 저장에 실패하면 `설정을 저장하지 못했습니다.`이며 파일은 그대로입니다. JSON이 깨져 읽히지 않으면 그 발화는 기본값(모드 `normal`, 음소거 꺼짐, 도우미 음성 켜짐)으로 재생됩니다.

```sh
debrief mute on
debrief mode night
debrief companion off
debrief status
```

처음 저장되면 이런 모양입니다. 키 순서는 저장 시 정렬됩니다.

```json
{
  "categoryVoices": {},
  "companionEnabled": true,
  "mode": "normal",
  "muted": false,
  "voiceSpeeds": {},
  "volumeCeilings": {
    "focus": 1,
    "night": 0.2,
    "normal": 1,
    "quiet": 0.45,
    "verbose": 1
  }
}
```

| 키 | 의미 | 바꾸는 명령 |
| --- | --- | --- |
| `muted` | 켜면 모든 발화를 재생하지 않습니다 | `debrief mute` |
| `mode` | `normal` `focus` `quiet` `verbose` `night` | `debrief mode` |
| `companionEnabled` | 끄면 companion lane만 빠집니다 | `debrief companion` |
| `volumeCeilings` | 모드별 볼륨 상한. 위 표의 기본값 | CLI는 이 맵을 바꾸지 않습니다 |
| `categoryVoices` | 역할 이름과 목소리. 비어 있으면 아래 역할 기본값 | 설치가 비워 둡니다 |
| `voiceSpeeds` | 역할별 속도. 비어 있으면 요청의 `speed` | 설치가 비워 둡니다 |

호스트 배선은 설정 파일과 별개입니다. `debrief install`이 절대 경로로 넣고, `debrief install --repair`가 소유한 파일만 다시 맞춥니다. 직접 고친 파일은 다이제스트가 다르면 남습니다.

| 호스트 | 파일 | 설치 후 |
| --- | --- | --- |
| Claude Code | `~/.claude.json` | `mcpServers.debrief`. Claude를 재시작 |
| Claude Code | `~/.claude/settings.json` | 시작 훅 |
| Claude Code | `~/.claude/skills/debrief-setup` `debrief-install` `debrief-speak` | 스킬 |
| Codex | `~/.codex/config.toml` | MCP 서버 `debrief` |
| Codex | `~/.codex/hooks.json` | 시작 훅. `/hooks`에서 신뢰 |
| Codex | `~/.agents/skills/` | 같은 세 스킬 |
| Grok | `~/.grok/config.toml` | `[mcp_servers.debrief]`. 훅은 없음. `/mcps` |
| Grok | `~/.grok/skills/` | 같은 세 스킬 |

Grok 조각은 이 형태입니다. `command`는 설치된 실행 파일의 절대 경로입니다.

```toml
# BEGIN debrief-mcp
[mcp_servers.debrief]
command = "/Users/you/.local/bin/debrief"
args = ["mcp"]
enabled = true
startup_timeout_sec = 15
tool_timeout_sec = 120
# END debrief-mcp
```

한 호스트만 다시 맞출 때는 `debrief install --claude --repair`처럼 플래그를 줍니다. MCP가 이미 되면 `install` 도구에 `{ "hosts": ["claude"], "repair": true }`를 넘깁니다.

## 에이전트가 말하는 방법

사용자에게 보이는 턴이 끝날 때 `speak`를 한 번 호출합니다. 두 문장, 사용자 언어: 무엇이 바뀌었는지, 다음에 할 행동 하나. 코드를 작성·수정·분석한 턴에서는 인지 부채를 줄이고 코드 오너십을 지키도록, 다음 행동이 사용자가 직접 확인해야 할 핵심(동작 변경, 삭제, 보안·데이터 경로, 에이전트의 가정, 확인·되돌리기 방법)이 됩니다. 새 사실도 다음 행동도 없으면 도구를 생략합니다. 채팅 본문에 발화 JSON이나 HTML 주석을 넣지 않습니다.

| 필드 | 필수 | 설명 |
| --- | --- | --- |
| `text` | 예 | 800자 이하 |
| `voice` | 예 | `F1`–`F5`, `M1`–`M5`. 도우미는 세션마다 이 목록을 돌고, 작업 레인은 역할표를 씁니다 |
| `speed` | 예 | 0.7–2.0. 도우미는 약 0.93 |
| `volume` | 예 | 0.0–1.0. 도우미는 약 0.85 |
| `priority` | 아니오 | `main` (기본) 또는 `subagent` |
| `lane` | 아니오 | `companion` (기본, 관찰) 또는 `work` (사실) |
| `emotion` | 아니오 | `neutral` `warm` `focused` `concerned` `relieved` `tired`. 재생 성향만 바꿉니다 |
| `session` | 아니오 | 호스트 세션 아이디. 같으면 도우미 목소리가 유지됩니다. 없으면 이 MCP 프로세스가 받은 목소리를 씁니다 |

서브에이전트는 사용자를 브리핑하지 않습니다. 말해야 하면 `priority=subagent`, `lane=work`, 사실 한 줄입니다.

도구 이름:

| 도구 | Claude Code | Grok |
| --- | --- | --- |
| `speak` | `mcp__debrief__speak` | `debrief__speak` |
| `install` | `mcp__debrief__install` | `debrief__install` |

Codex 도구 이름은 서버 `debrief`의 `speak`와 `install`입니다. Grok은 필요하면 `search_tool` 다음 `use_tool`입니다.

`install` 인자 `hosts`는 `codex`, `claude`, `grok` 배열이고 생략하면 전체입니다. `repair` 기본값은 `true`입니다. 첫 모델 다운로드는 MCP 시간 제한을 넘길 수 있으니 그때는 셸 `debrief install`을 씁니다.

역할별 기본 목소리는 reviewer `M2`, planner `M1`, builder `M4`, tester `F2`, explorer `F3`, optimizer `M3`, guardian `M5`, ops `F4`, specialist `F5`, 그 외 `F1`입니다. 역할마다 목소리가 다릅니다.

도우미 목소리는 세션마다 `F1`부터 `M5`까지 돌아갑니다. 같은 세션 아이디는 같은 목소리를 유지하고, 열 개를 넘기면 처음부터 다시 씁니다. `speak`의 `session`에 호스트 세션 아이디를 넘기면 그 목소리로 재생합니다. 아이디가 없으면 그 MCP 프로세스가 받은 목소리로 재생합니다. 작업 레인은 역할표를 그대로 씁니다.

## 디스크

```text
~/.local/bin/debrief
~/Library/Application Support/debrief/config.json
~/Library/Application Support/debrief/models/
~/Library/Application Support/debrief/install-manifest.json
~/Library/Application Support/debrief/session-voices.json
~/Library/Caches/debrief/debrief.sock
~/Library/Caches/debrief/daemon.pid
~/Library/Caches/debrief/last-error.json
~/Library/LaunchAgents/com.debrief.tts.plist
```

## 문서

| 문서 | 내용 |
| --- | --- |
| [ONBOARDING.md](ONBOARDING.md) | 첫 설치와 매일 쓰는 명령 |
| [DEVELOPER.md](DEVELOPER.md) | 빌드, 구조, 변경 규칙 |
| [docs/superpowers/specs/2026-09-29-daemon-single-binary-design.md](docs/superpowers/specs/2026-09-29-daemon-single-binary-design.md) | 데몬과 CLI 계약. 본문 식별자는 초안의 chorus |
| [docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md](docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md) | MCP speak / install |
| [docs/superpowers/specs/2026-07-22-reflective-companion-design.md](docs/superpowers/specs/2026-07-22-reflective-companion-design.md) | lane, emotion, 도우미 음성 |
| [docs/superpowers/specs/2026-09-30-rust-rewrite-design.md](docs/superpowers/specs/2026-09-30-rust-rewrite-design.md) | Rust 재작성: 크레이트 경계, 배포 파이프라인 |
| [docs/archive/](docs/archive/) | Python 시대 기록. 현재 제품 설명이 아님 |
