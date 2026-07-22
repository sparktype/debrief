# voice-persona 원클릭 설치 + 리네이밍 설계

**날짜**: 2026-05-24  
**프로젝트**: voice-persona (구 chorus / siren-mcp)  
**목표**: 공개 배포를 위한 원클릭 설치, hook 최적화, 프로젝트 전면 리네이밍, README 사용자 가이드 개편

---

## 1. 리네이밍 맵

| 변경 전 | 변경 후 |
|---------|---------|
| `chorus` / `siren-mcp` / `siren` | `voice-persona` |
| `.siren.json` | `.voice-persona.json` |
| `SirenConfig` (TypeScript 인터페이스) | `VoicePersonaConfig` |
| `/tmp/siren-tts.lock` | `/tmp/voice-persona.lock` |
| `siren_edge_*`, `siren_st_*`, `siren_tts_*` (임시파일 prefix) | `vp_edge_*`, `vp_st_*`, `vp_tts_*` |
| `SIREN_DATA_DIR` | `VOICE_PERSONA_DATA_DIR` |
| `SIREN_OFFLINE` | `VOICE_PERSONA_OFFLINE` |
| `SIREN_VENV_PYTHON` | `VOICE_PERSONA_VENV_PYTHON` |
| `~/.local/share/chorus/` | `~/.local/share/voice-persona/` |
| `com.chorus.tts-server` (launchd label) | `com.voice-persona.tts-server` |
| `/tmp/chorus-tts.log` | `/tmp/voice-persona-tts.log` |

### 영향 파일 목록

| 파일 | 변경 내용 |
|------|---------|
| `package.json` | `name` 필드 |
| `package-lock.json` | `name` 필드 |
| `src/config.ts` | 설정 파일명, 인터페이스명, env var |
| `src/player.ts` | lock 파일, 임시파일 prefix, env var 3개 |
| `src/last-message-store.ts` | 데이터 디렉토리, env var |
| `src/skill-recommender.ts` | 데이터 디렉토리, env var |
| `src/index.ts` | MCP 서버 표시명 |
| `tts_server/server.py` | `mkdtemp(prefix=...)` |
| `server.sh` | launchd label, plist 경로, 로그 경로, 출력 문자열 |
| `setup-tts.sh` | 동일 |
| `tests/player.test.ts` | env var 이름 |
| `tests/last-message-store.test.ts` | env var 이름, 데이터 디렉토리 |
| `CLAUDE.md` | env var 참조, 경로 |
| `ONBOARDING.md` | lock 파일 경로 참조 |

**docs/superpowers/** 기존 planning 문서는 역사 기록으로 유지(수정 없음).

---

## 2. 원클릭 설치 스크립트 (`install.sh`)

### 설치 명령

```bash
curl -fsSL https://raw.githubusercontent.com/sparktype/voice-persona/main/install.sh | bash
```

### 설치 경로

`~/.local/share/voice-persona/` 고정 (환경변수로 오버라이드 불가, 예측 가능한 단일 경로)

### 7단계 순차 실행

```
[1/7] 환경 확인
[2/7] 저장소 클론 / 업데이트
[3/7] Node.js 빌드
[4/7] Python 환경 구성
[5/7] MLX 모델 캐시 (선택)
[6/7] Claude Code hooks 등록
[7/7] TTS Player LaunchAgent 등록
```

#### 단계별 상세

**1. 환경 확인**
- CPU: `uname -m` → `arm64` 아니면 중단 (MLX = Apple Silicon 전용)
- macOS: `sw_vers -productVersion` → 13.0 미만이면 중단
- Node.js: `node --version` → 18.0 미만이면 Homebrew 설치 안내 후 중단
- Python: `python3 --version` → 3.11 미만이면 안내 후 중단
- Claude Code: `claude --version` → 없으면 설치 URL 안내 후 중단

**2. 저장소 클론 / 업데이트**
- 없으면 `git clone`
- 있으면 `git pull` (기존 설치 업데이트 지원)

**3. Node.js 빌드**
- `npm ci && npm run build`
- 실패 시 npm 오류 출력 후 중단

**4. Python 환경**
- `python3 -m venv tts-venv`
- `tts-venv/bin/pip install -q mlx-audio edge-tts fastapi uvicorn`
- 실패 시 pip 오류 출력 후 중단

**5. MLX 모델 캐시**
- 프롬프트로 다운로드 여부 확인 (약 800MB)
- `--skip-model` 플래그로 비대화형 스킵 가능
- 실패 시 경고만, 설치 계속 (Edge TTS fallback 있음)

**6. Claude Code hooks 등록**
- `~/.claude/settings.json` 읽기 → JSON 파싱 → hooks 섹션 패치 → 기록
- 없으면 새로 생성
- 4개 hook 등록: `Stop`, `SubagentStop`, `UserPromptSubmit`, `SessionStart`
- hook 경로는 설치 경로 기준 절대 경로
- 이미 등록된 경우 덮어쓰지 않음 (멱등)

**7. LaunchAgent 등록**
- `~/Library/LaunchAgents/com.voice-persona.tts-player.plist` 생성
- `launchctl load` 실행
- 실패 시 경고 + 수동 등록 방법 출력

### 완료 메시지

```
✓ voice-persona 설치 완료

  작동 확인 : node ~/.local/share/voice-persona/dist/index.js test
  설정 파일 : ~/.voice-persona.json (없으면 기본값 사용)
  제거      : bash ~/.local/share/voice-persona/uninstall.sh
```

### `uninstall.sh`

- LaunchAgent unload + plist 삭제
- `~/.claude/settings.json`에서 hooks 항목 제거
- 설치 디렉토리 삭제 확인 후 삭제

---

## 3. Hook 최적화

### 원칙

- 모든 `python3 -c "import json..."` 인라인 파싱 제거
- 원시 JSON을 그대로 `node dist/index.js <command>` stdin으로 전달
- JSON 파싱 책임을 TypeScript(`src/index.ts`)로 이전
- 각 훅 스크립트는 5~8줄 이내

### 변경 전 → 후 비교

**stop.sh** (10줄 → 5줄)
```bash
#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" hook > /dev/null 2>&1 &
disown $!; exit 0
```

**subagent-stop.sh** (45줄 → 8줄)
```bash
#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" subagent-stop > /dev/null 2>&1 &
disown $!; exit 0
```

**prompt-submit.sh** (15줄 → 8줄)
```bash
#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup node "$SCRIPT_DIR/../dist/index.js" hook-suggest > /dev/null 2>&1 &
disown $!; exit 0
```

**session-start.sh** (정리만, 이미 Python 없음)

### `src/index.ts` 수정

`hook`, `subagent-stop`, `hook-suggest` 명령에서 stdin을 raw string으로 읽어 JSON 파싱:

```typescript
// hook 명령
const raw = await readStdin();
let data: Record<string, unknown> = {};
try { data = JSON.parse(raw); } catch { /* 비어있거나 텍스트면 무시 */ }
const text = (data.last_assistant_message as string) ?? raw;
```

`subagent-stop` 명령에서는 `transcript_path`와 JSONL 파싱을 TypeScript에서 처리 (현재 일부는 이미 TS에서 하고 있음).

---

## 4. README.md 구성 (사용자 가이드)

```markdown
# voice-persona
Claude Code 응답을 자동으로 음성으로 읽어주는 MCP 서버

## 요구 사항
- macOS + Apple Silicon (M1/M2/M3/M4)
- Claude Code CLI
- Node.js 18+, Python 3.11+

## 설치 (1분)
curl -fsSL ... | bash

## 기본 사용법
설치 후 Claude Code에서 자동 작동. 별도 설정 불필요.

## 설정 (.voice-persona.json)
목소리, 속도, 최소 글자 수 등 자주 쓰는 옵션 표

## MCP 도구
speak_text / summarize_and_speak / set_config 사용 예시

## 에이전트 음성 (다성 TTS)
서브에이전트별 다른 목소리 설정 방법

## 문제 해결
소리가 안 날 때 / 모델 로딩 실패 / Hook 미작동

## 제거
bash ~/.local/share/voice-persona/uninstall.sh

<details><summary>개발자 가이드</summary>
아키텍처, 빌드, 테스트, 환경변수 전체 목록
</details>
```

---

## 5. 구현 작업 분할 (팀 병렬)

| 작업 | 담당 에이전트 | 의존성 |
|------|-------------|--------|
| A. 리네이밍 — 소스 코드 전체 | Agent-Rename | 없음 |
| B. Hook 최적화 (shell + src/index.ts stdin 처리) | Agent-Hook | 없음 |
| C. install.sh + uninstall.sh 신규 작성 | Agent-Installer | A 완료 후 |
| D. README.md 사용자 가이드 전면 개편 | Agent-Docs | A 완료 후 |

A·B는 완전 독립 → 병렬 시작  
C·D는 A 완료 확인 후 시작

---

## 6. 검증 기준

- [ ] `npm run build` 오류 없음
- [ ] `npm test` 전체 통과
- [ ] `grep -r "siren\|summary.voice\|summary_voice\|SIREN" src/ hooks/ tts_server/ *.sh *.json` 결과 없음
- [ ] `curl ... | bash` 실행 후 Claude Code 재시작 시 hook 4개 자동 작동
- [ ] `.voice-persona.json` 생성 시 설정 오버라이드 정상 동작
- [ ] `uninstall.sh` 실행 후 launchd + hooks 흔적 없음
