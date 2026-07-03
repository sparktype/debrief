---
name: chorus:hud
description: "claude-hud와 chorus HUD 레이블을 연동합니다. /chorus:hud 를 실행하면 현재 statusline 설정을 확인하고 --extra-cmd 연동 명령어를 안내합니다."
---

# chorus:hud — HUD 레이블 연동 설정

claude-hud의 `--extra-cmd` 옵션으로 chorus TTS 상태를 statusline에 표시합니다.

> **주의**: statusline 경로에서 LLM·외부 네트워크 호출을 하면 안 됩니다.
> `hud-label` 커맨드는 LLM·외부 네트워크 호출 없음 (로컬 서버 접근 후 파일 폴백):
> 로컬 서버(127.0.0.1:7777, 250ms timeout) → 스냅샷 파일(`~/.local/share/chorus/hud.json`) → 오프라인 순서로 폴백합니다.

---

## 1단계 — 현재 설정 확인

```bash
# 현재 HUD 레이블 출력 확인
.venv/bin/python -m hook_voice hud-label
# 서버 실행 중: → {"label": "🔊 normal [F1]"}
# 서버 오프라인·스냅샷 없음: → {"label": "chorus offline"}

# TTS 서버 상태 확인
./server.sh status
```

---

## 2단계 — claude-hud 버전 확인

claude-hud 캐시 경로에서 설치된 버전을 확인합니다.

```bash
ls $HOME/.claude/plugins/cache/claude-hud/claude-hud/
# → 0.1.0  (설치된 버전 디렉터리)
```

아래 명령어의 `<VERSION>`을 실제 버전으로, `<PROJECT_DIR>`을 프로젝트 절대 경로로 치환합니다.

---

## Path A — claude-hud 직접 사용

claude-hud를 단독 statusline으로 사용하는 경우입니다.

```bash
node $HOME/.claude/plugins/cache/claude-hud/claude-hud/<VERSION>/dist/index.js \
  --extra-cmd "cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label"
```

예시 (버전 0.1.0, 프로젝트 경로 `<PROJECT_DIR>`):

```bash
node $HOME/.claude/plugins/cache/claude-hud/claude-hud/0.1.0/dist/index.js \
  --extra-cmd "cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label"
```

---

## Path B — claudenews parentStatusLine

claudenews가 이미 외부 HUD로 활성화된 경우, `~/.claudenews/config.json`에 추가합니다.

```json
{
  "parentStatusLine": "node $HOME/.claude/plugins/cache/claude-hud/claude-hud/<VERSION>/dist/index.js --extra-cmd \"cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label\""
}
```

예시:

```json
{
  "parentStatusLine": "node $HOME/.claude/plugins/cache/claude-hud/claude-hud/0.1.0/dist/index.js --extra-cmd \"cd <PROJECT_DIR> && .venv/bin/python -m hook_voice hud-label\""
}
```

이 방식은 기존 claudenews statusline을 유지하면서 chorus 레이블을 추가합니다.

---

## 트러블슈팅

### 레이블이 stale하거나 업데이트되지 않을 때

TTS 서버가 실행 중일 때는 Stop hook 완료 후 스냅샷이 자동 갱신됩니다.  
서버 API로 최신 스냅샷을 직접 확인합니다.

```bash
curl -s localhost:7777/chorus/hud
# → {"mode": "normal", "voice": "F1", "auto_speak": true, "label": "🔊 normal [F1]"}
```

### 서버가 오프라인일 때

서버가 꺼져 있어도 `hud-label`은 마지막 스냅샷 파일(`~/.local/share/chorus/hud.json`)을 읽어 반환합니다.  
스냅샷 파일 자체가 없으면 `{"label": "chorus offline"}`을 출력합니다.

```bash
# 직접 확인
.venv/bin/python -m hook_voice hud-label
```

### HUD 레이블 실시간 확인

```bash
# 1초 간격으로 레이블 모니터링
watch -n 1 ".venv/bin/python -m hook_voice hud-label"
```

### claude-hud 플러그인 경로를 모를 때

```bash
find $HOME/.claude/plugins -name "index.js" 2>/dev/null | grep claude-hud
```
