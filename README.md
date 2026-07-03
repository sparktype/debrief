# chorus

> Claude Code 응답을 자동으로 음성으로 읽어주는 hook 기반 TTS 시스템

Claude Code가 응답을 완료하면 자동으로 요약해서 읽어줍니다.  
멀티 에이전트 팀 작업 시 에이전트마다 다른 목소리로 발화합니다.

개발자 가이드는 [DEVELOPER.md](DEVELOPER.md)를 참고하세요.

---

## 요구 사항

- macOS + Apple Silicon (M1/M2/M3/M4)
- [Claude Code CLI](https://claude.ai/code)
- Python 3.12+

---

## 설치

```bash
git clone https://github.com/sparktype/chorus.git
cd chorus
./setup-tts.sh        # .venv 생성 + MLX 모델 다운로드
./server.sh install   # launchd + Stop hook 자동 등록
```

설치 후 Claude Code를 재시작하면 자동으로 활성화됩니다.

---

## 기본 동작

별도 설정 없이 바로 작동합니다.

| 이벤트 | 동작 |
|--------|------|
| Claude Code 응답 완료 | 자동 요약 → 음성 재생 (`🎙️ 요약 중...` → `▶️ 재생 중`) |
| 서브에이전트 응답 | 역할에 맞는 목소리 + earcon 전환음 |
| `/listen` slash 명령 | Whisper STT 음성 입력 (선택) |
| `/mute` slash 명령 | 음소거 토글 — 켜져 있으면 끄고, 꺼져 있으면 켜기 |

---

## 설정 파일 (`.voice.json`)

프로젝트 루트에 생성하면 기본값을 오버라이드합니다.

```json
{
  "autoSpeak": true,
  "minChars": 50,
  "ttsSpeed": 1.1,
  "voiceMode": "normal",
  "summaryModel": "gemini-3.5-flash",
  "usageTracking": true,
  "bridgeEnabled": false,
  "resumeThreshold": 0.0,
  "stt": {
    "enabled": false,
    "vadInterrupt": false
  }
}
```

### 주요 설정 키

| 키 | 기본값 | 설명 |
|----|--------|------|
| `autoSpeak` | `true` | 자동 재생 여부 |
| `minChars` | `50` | 이 글자 수 이하면 TTS 건너뜀 |
| `ttsSpeed` | `1.1` | 재생 속도 (afplay -r) |
| `voiceMode` | `"normal"` | 현재 음성 프리셋 모드 |
| `summaryModel` | `"gemini-3.5-flash"` | 요약에 사용할 LLM 모델 |
| `speechRetouch` | `true` | LLM으로 마크다운 제거·IT 용어 발음 변환 |
| `usageTracking` | `true` | 사용 패턴 통계 수집 여부 |
| `bridgeEnabled` | `false` | 침묵 제거 브리지 음 재생 opt-in |
| `bridgeThresholdMs` | `500` | 브리지 재생 최소 텍스트 길이 (글자 수) |
| `resumeThreshold` | `0.0` | 중단 후 재개 임계값 (0.0 = 항상 포기) |

### STT 설정 (`stt` 블록)

| 키 | 기본값 | 설명 |
|----|--------|------|
| `stt.enabled` | `false` | Whisper STT 활성화 |
| `stt.model` | `mlx-community/whisper-small-mlx` | Whisper 모델 |
| `stt.language` | `"ko"` | 인식 언어 |
| `stt.announce` | `true` | 녹음 시작/완료 TTS 안내 |
| `stt.vadInterrupt` | `false` | 발화 감지 시 TTS 자동 중단 (opt-in) |

---

## 음성 모드 프리셋

작업 상황에 맞게 여러 설정을 한 번에 바꿀 수 있습니다.

```bash
python -m hook_voice mode list
python -m hook_voice mode set focus     # 긴 응답 위주로 줄여 듣기
python -m hook_voice mode set quiet     # 방해 최소화
python -m hook_voice mode set verbose   # 짧은 응답도 적극 발화
python -m hook_voice mode set night     # 느리고 차분한 야간 모드
python -m hook_voice mode set normal    # 기본값
```

---

## 에이전트 음성 (다성 TTS)

멀티 에이전트 팀 작업 시 에이전트 타입별로 다른 목소리로 발화합니다.  
`voice-map.json`을 편집해 매핑을 변경할 수 있습니다 — 코드 수정 없이 JSON만 바꾸면 됩니다.

| Voice ID | 이름 | 역할 |
|----------|------|------|
| F1 | 연아 | 메인 응답 (default) |
| F2 | 마리 | tester |
| F3 | 제인 | explorer |
| F4 | 셰릴 | ops |
| F5 | 리사 | specialist |
| M1 | 스티브 | planner |
| M2 | 빌 | reviewer |
| M3 | 일론 | optimizer |
| M4 | 리누스 | builder |
| M5 | 팀 | guardian |

에이전트 전환 시 `earcon_switch.wav` (0.3초 880Hz 감쇠 톤)이 먼저 재생됩니다.  
`voice-map.json`의 `earcon.enabled: false`로 비활성화할 수 있습니다.

CLI로도 서브에이전트 카테고리별 목소리를 바꿀 수 있습니다.

```bash
python -m hook_voice setup voice list
python -m hook_voice setup voice set reviewer F3
python -m hook_voice setup voice set builder M4
python -m hook_voice setup voice speed M2 0.9
python -m hook_voice setup voice steps M2 10
```

---

## 스마트 발화 정책

응답 내용에 따라 발화 방식과 우선순위를 자동 결정합니다.

| 응답 유형 | 발화 방식 | 우선순위 |
|-----------|-----------|---------|
| 에러·실패 키워드 포함 | 전체 낭독 | **HIGH** — 기존 재생 즉시 선점 |
| 코드 블록 40%+ | `[N줄 코드]와 함께 완료됐습니다` 축약 | NORMAL |
| 짧은 확인 응답 | earcon 음만 재생 | LOW |
| 일반 응답 | 전체 낭독 | NORMAL |

**우선순위 큐:**
- **HIGH**: 대기 중인 모든 발화를 즉시 제거하고 선점
- **NORMAL**: 최대 3개, 30초 TTL 초과 시 자동 만료
- **LOW**: 큐가 비어있을 때만 추가

---

## Whisper STT 음성 입력

마이크로 말하면 텍스트로 변환해 현재 포커스 위치에 붙여넣습니다 (Apple Silicon MLX 가속).

**활성화:**
```json
{ "stt": { "enabled": true } }
```

**사용법:**

| 방법 | 동작 |
|------|------|
| `/listen` slash 명령 | 녹음 시작/중지 토글 |
| Hammerspoon `Cmd+Shift+Space` | 동일 |
| `curl -X POST localhost:7777/stt/toggle` | API 직접 호출 |

**Hammerspoon 단축키** (`~/.hammerspoon/init.lua`):
```lua
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  hs.task.new("/usr/bin/curl", nil, {"-s", "-X", "POST", "http://localhost:7777/stt/toggle"}):start()
end)
```

---

## 자동 학습·적응

TTS 사용 패턴(완료율·중단 빈도·에이전트별)을 로컬에 익명 수집해 설정 개선안을 제안합니다.  
제안은 자동으로 적용되지 않습니다 — 항상 명시적 실행 후 확인 과정이 필요합니다.

```bash
python -m hook_voice suggest-config   # 설정 권장안 출력
python -m hook_voice privacy status   # 통계 파일 위치·건수 확인
python -m hook_voice privacy clear    # 모든 통계 데이터 삭제
```

통계는 `~/.local/share/chorus/usage_stats.jsonl`에 로컬 저장됩니다.  
수집을 원하지 않으면 `.voice.json`에 `"usageTracking": false`를 추가하세요.

---

## 재생 제어

```bash
# 음소거 토글 (slash 명령 또는 CLI)
# Claude Code에서: /mute
python -m hook_voice mute             # autoSpeak on/off 토글 (해제 시 음성으로 안내)

# CLI
python -m hook_voice control skip     # 현재 트랙 건너뜀
python -m hook_voice control flush    # 재생 큐 비우기
python -m hook_voice control pause    # 일시정지
python -m hook_voice control resume   # 재개

# API
curl -X POST localhost:7777/interrupt         # TTS 즉시 중단 (SIGTERM→SIGKILL)
curl localhost:7777/playback/status           # 재생 상태 + 큐 깊이
curl localhost:7777/health                    # 서버 헬스 체크
```

---

## TTS 어시스턴트 모드

`assistantTts.enabled: true`(기본값)이면 LLM이 각 hook 이벤트를 분석해 TTS 발화 내용을 생성합니다.  
설정을 변경해도 TTS 서버는 재시작하지 않아도 됩니다 — 다음 hook 호출 시 자동 반영됩니다.

| hook 이벤트 | LLM 역할 | 발화 방식 |
|-------------|----------|---------|
| **Stop** (Claude 응답 완료) | 응답을 10~12초 분량으로 브리핑 — 결론·변경 파일·검증·다음 단계 순 | TTS 발화 |
| **PostToolUse Bash** (명령 실패) | 실패 명령·에러 라인·원인·다음 단계를 1~2문장으로 설명 | TTS 발화 |
| **PreToolUse Bash** (고위험 명령 실행 전) | `rm -rf`, `git reset --hard` 등 위험 패턴 감지 시 1문장 경고 | TTS 발화 |
| **UserPromptSubmit** (프롬프트 입력) | 프롬프트 의도 분석 → `focus/quiet/verbose` voiceMode 추천 | TTS 발화 (모드 변경은 명시적 승인 필요) |

**스냅샷 위치 (HUD용)**: `~/.local/share/chorus/hud.json`  
HUD에 표시되는 라벨(`🔊 normal [F1]`)은 이 파일에서 읽으며, LLM 호출 없이 로컬 파일만 사용합니다.

### 어시스턴트 설정 (`assistantTts` 블록)

`.voice.json`에 추가해 어시스턴트 동작을 조정합니다.

```json
{
  "assistantTts": {
    "enabled": true,
    "briefingMode": "smart",
    "llmTimeoutMs": 2500,
    "failureExplain": true,
    "riskExplain": true,
    "promptAdvice": true
  }
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `enabled` | `true` | LLM 어시스턴트 전체 활성화 여부 |
| `briefingMode` | `"smart"` | Stop hook 브리핑 방식 (`"smart"` = 자동, `"always"` = 항상 LLM) |
| `llmTimeoutMs` | `2500` | LLM 호출 타임아웃 (ms) — 초과 시 규칙 기반 폴백 |
| `failureExplain` | `true` | PostToolUse Bash 실패 설명 활성화 여부 |
| `riskExplain` | `true` | PreToolUse Bash 위험 경고 활성화 여부 |
| `promptAdvice` | `true` | UserPromptSubmit voiceMode 추천 활성화 여부 |

LLM 어시스턴트는 opt-in/configurable이며 자동으로 설정을 변경하지 않습니다.  
voiceMode 추천은 안내만 할 뿐이며 실제 변경은 사용자가 `python -m hook_voice mode set <mode>` 명령으로 직접 실행해야 합니다.

---

## 세션 다이제스트

현재 세션에서 chorus가 처리한 TTS 이벤트를 시간 순으로 요약합니다.

```bash
python -m hook_voice digest             # 마지막 10개 이벤트 요약
python -m hook_voice digest --last 20   # 마지막 20개 이벤트 요약
```

출력 예시:
```
[14:32] Stop hook — 파일 3개 수정, 테스트 통과 요약
[14:35] Failure — pytest tests/test_foo.py: AssertionError 1건
[14:41] Stop hook — ONBOARDING.md 업데이트 완료
```

---

## 프라이버시 및 데이터 흐름

### 로컬 저장 (LLM 전송 없음)

| 데이터 | 경로 | 설명 |
|--------|------|------|
| HUD 스냅샷 | `~/.local/share/chorus/hud.json` | TTS 상태, 재생 중 여부 |
| 사용 통계 | `~/.local/share/chorus/usage_stats.jsonl` | 완료율·중단 빈도 (익명) |
| 브리핑 캐시 | 메모리 내 | 세션 종료 시 자동 삭제 |

### LLM으로 전송되는 항목

| 트리거 | 전송 내용 | 목적 |
|--------|----------|------|
| Stop hook (응답 완료) | Claude 응답 텍스트 (최대 3,000자) | 브리핑 생성 |
| PostToolUse 실패 | 명령어·exit code·마지막 30줄 출력 | 실패 설명 |
| PreToolUse 위험 명령 | 명령어 문자열 | 위험 경고 |
| UserPromptSubmit | 프롬프트 (최대 400자) + 컨텍스트 (최대 600자) | voiceMode 추천 |

**자동 redact**: 30자 이상 영숫자+특수문자 연속 패턴은 `[REDACTED]`로 치환 후 LLM에 전송합니다.  
**수집 거부**: `"usageTracking": false`로 로컬 통계 수집을 중단할 수 있습니다.  
**통계 삭제**: `python -m hook_voice privacy clear`로 모든 통계 데이터를 즉시 삭제합니다.

---

## HUD 연동

Claude Code statusline에 chorus TTS 상태를 표시합니다.

### hud-label 커맨드

```bash
.venv/bin/python -m hook_voice hud-label
# → {"label": "🔊 normal [F1]"}
```

LLM·외부 네트워크 호출 없음 (로컬 서버 접근 후 파일 폴백).
로컬 서버(127.0.0.1:7777, 250ms timeout) → 스냅샷 파일(`~/.local/share/chorus/hud.json`) → `{"label": "chorus offline"}` 순서로 폴백합니다.
TTS 서버가 Stop hook을 처리할 때마다 스냅샷을 자동 갱신합니다.

### claude-hud --extra-cmd 연동

아래 `<VERSION>`과 `<PROJECT_DIR>`을 실제 값으로 치환합니다.

**Path A — claude-hud 직접 사용:**

```bash
node $HOME/.claude/plugins/cache/claude-hud/claude-hud/<VERSION>/dist/index.js \
  --extra-cmd "cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label"
```

**Path B — claudenews parentStatusLine** (`~/.claudenews/config.json`):

```json
{
  "parentStatusLine": "node $HOME/.claude/plugins/cache/claude-hud/claude-hud/<VERSION>/dist/index.js --extra-cmd \"cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label\""
}
```

기존 claudenews statusline을 유지하면서 chorus 레이블을 추가하는 방식입니다.

### GET /chorus/hud API

TTS 서버가 실행 중일 때 실시간 상태를 확인합니다.

```bash
curl -s localhost:7777/chorus/hud
# → {"mode": "normal", "voice": "F1", "auto_speak": true, "label": "🔊 normal [F1]"}
```

자세한 설정 방법은 `/chorus:hud` 스킬을 실행하거나 `.claude/skills/chorus-hud/SKILL.md`를 참고하세요.

---

## 서버 관리

```bash
./server.sh start      # 수동 시작
./server.sh stop       # 종료
./server.sh restart    # 재시작
./server.sh status     # 상태 확인 (서버·모델·hook 등록 여부)
./server.sh logs [N]   # 마지막 N줄 로그 (기본 50)
./server.sh install    # launchd + Stop hook 등록
./server.sh uninstall  # 완전 제거
```

---

## 진단

```bash
python -m hook_voice setup status       # 설정 파일·모드·voice-map 상태 확인
python -m hook_voice setup defaults     # 기본 .voice.json 생성/보강
python -m hook_voice doctor           # TTS 시스템 전체 진단
python -m hook_voice voice test       # 기본 목소리 TTS 테스트
python -m hook_voice voice test M2 "안녕하세요"  # 특정 목소리 테스트
```

---

## 문제 해결

**소리가 전혀 안 날 때**
```bash
python -m hook_voice doctor    # 전체 진단 — 연결·모델·서버 상태 한 번에 확인
./server.sh status             # TTS 서버 + hook 등록 여부
./server.sh restart            # 서버 재시작
```

**음성이 중간에 잘릴 때**  
`chunk_for_tts`가 80자 단위 문장 분할을 자동으로 처리합니다.  
마침표·물음표·느낌표가 없는 긴 문장은 단일 청크로 처리될 수 있습니다.

**MLX 모델 로딩 실패**
```bash
uname -m               # arm64 이어야 함
tail -f .tts_server.log
```

**Hook이 작동 안 할 때**
```bash
cat ~/.claude/settings.json | grep -A5 '"Stop"'
./server.sh install    # hook 재등록
```

**HUD 레이블이 표시 안 될 때**
```bash
.venv/bin/python -m hook_voice hud-label       # HUD 레이블 직접 확인
curl -s localhost:7777/chorus/hud              # 서버 실시간 HUD 상태
curl -s localhost:7777/playback/status         # 재생 큐 상태 확인
.venv/bin/python -m hook_voice privacy status  # 통계 파일 위치·건수 확인
```

**LLM 어시스턴트 브리핑이 안 될 때**
```bash
# .voice.json 어시스턴트 설정 확인
cat .voice.json | grep -A8 '"assistantTts"'
# LLM 타임아웃 조정 (기본 2500ms)
# {"assistantTts": {"llmTimeoutMs": 5000}}
```

**제거**
```bash
./server.sh uninstall
```
