#!/usr/bin/env bash
# AI 코딩 도구별 voice hook 등록/해제
# 사용법: ./install.sh [--uninstall] <tool> [<tool2>...]
# 지원 도구: claude | codex | opencode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"

# ── 인수 파싱 ──────────────────────────────────────────────

UNINSTALL=false
TOOLS=()

for arg in "$@"; do
  case "$arg" in
    --uninstall|-u|uninstall) UNINSTALL=true ;;
    claude|codex|opencode)    TOOLS+=("$arg") ;;
    *)
      echo "알 수 없는 인수: $arg" >&2
      echo "사용법: $(basename "$0") [--uninstall] <tool> [<tool2>...]" >&2
      echo "지원 도구: claude | codex | opencode" >&2
      exit 1
      ;;
  esac
done

if [[ ${#TOOLS[@]} -eq 0 ]]; then
  echo "사용법: $(basename "$0") [--uninstall] <tool> [<tool2>...]"
  echo "지원 도구: claude | codex | opencode"
  echo ""
  echo "예시:"
  echo "  ./install.sh claude                   # Claude Code hook 등록"
  echo "  ./install.sh claude codex opencode    # 복수 등록"
  echo "  ./install.sh --uninstall claude       # hook 제거"
  exit 1
fi

# ── Claude Code ────────────────────────────────────────────
# 설정 파일: ~/.claude/settings.json
# hook 포맷: {hooks: {Stop:[...], SubagentStop:[...], ...}}

install_claude() {
  local settings="$HOME/.claude/settings.json"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  python3 - "$settings" "$HOOKS_DIR" << 'PYEOF'
import json, sys

settings_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    data = json.load(f)

if "hooks" not in data:
    data["hooks"] = {}

def add_hook(sec, matcher, script, timeout):
    cmd = hooks_dir + "/" + script
    existing = data["hooks"].get(sec, [])
    # 동일 section·matcher 조합에서 이미 이 커맨드가 있으면 추가하지 않음
    for entry in existing:
        if not isinstance(entry, dict):
            continue
        if entry.get("matcher") != matcher:
            continue
        if any(h.get("command") == cmd for h in entry.get("hooks", [])):
            return
    existing.append({
        "matcher": matcher,
        "hooks": [{"type": "command", "command": cmd, "timeout": timeout}]
    })
    data["hooks"][sec] = existing

add_hook("Stop",             "", "stop.sh",             15)
add_hook("SubagentStop",     "", "subagent-stop.sh",    15)
add_hook("Notification",     "", "notification.sh",     10)
add_hook("UserPromptSubmit", "", "prompt-submit.sh",    10)
add_hook("SessionStart",     "", "session-start.sh",    10)
add_hook("PreToolUse",  "Bash", "pre-tool-bash.sh",      5)
add_hook("PreToolUse", "Monitor", "pre-tool-monitor.sh", 5)
add_hook("PostToolUse", "Bash", "post-tool-bash.sh",     5)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ Claude Code — 8종 hook 등록 완료"
  echo "    파일: $HOME/.claude/settings.json"
}

uninstall_claude() {
  local settings="$HOME/.claude/settings.json"
  [[ -f "$settings" ]] || { echo "  Claude Code 설정 파일 없음, 건너뜀"; return; }

  python3 - "$settings" "$HOOKS_DIR" << 'PYEOF'
import json, sys

settings_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    data = json.load(f)

hooks = data.get("hooks", {})
for sec in list(hooks.keys()):
    filtered = [h for h in hooks[sec] if hooks_dir not in json.dumps(h)]
    if filtered:
        hooks[sec] = filtered
    else:
        del hooks[sec]

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ Claude Code hook 제거 완료"
}

# ── Codex CLI ──────────────────────────────────────────────
# 설정 파일: ~/.codex/hooks.json
# hook 포맷: Claude Code와 동일 (Stop, SubagentStop, PreToolUse, PostToolUse)

install_codex() {
  local hooks_file="$HOME/.codex/hooks.json"
  mkdir -p "$(dirname "$hooks_file")"
  [[ -f "$hooks_file" ]] || echo '{"hooks":{}}' > "$hooks_file"

  python3 - "$hooks_file" "$HOOKS_DIR" << 'PYEOF'
import json, sys

hooks_file, hooks_dir = sys.argv[1], sys.argv[2]

with open(hooks_file) as f:
    data = json.load(f)

if "hooks" not in data:
    data["hooks"] = {}

def add_hook(sec, matcher, script, timeout):
    cmd = hooks_dir + "/" + script
    existing = data["hooks"].get(sec, [])
    if not any(
        isinstance(h, dict) and h.get("matcher") == matcher
        and cmd in json.dumps(h.get("hooks", []))
        for h in existing
    ):
        existing.append({
            "matcher": matcher,
            "hooks": [{"type": "command", "command": cmd, "timeout": timeout}]
        })
    data["hooks"][sec] = existing

# Codex는 Claude Code와 동일한 hook 포맷 사용 (Stop, SubagentStop, PreToolUse, PostToolUse)
add_hook("Stop",         "", "stop.sh",          15)
add_hook("SubagentStop", "", "subagent-stop.sh", 15)
add_hook("PreToolUse",  "Bash", "pre-tool-bash.sh",  5)
add_hook("PostToolUse", "Bash", "post-tool-bash.sh", 5)

with open(hooks_file, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ Codex — 4종 hook 등록 완료"
  echo "    파일: $HOME/.codex/hooks.json"
}

uninstall_codex() {
  local hooks_file="$HOME/.codex/hooks.json"
  [[ -f "$hooks_file" ]] || { echo "  ~/.codex/hooks.json 없음, 건너뜀"; return; }

  python3 - "$hooks_file" "$HOOKS_DIR" << 'PYEOF'
import json, sys

hooks_file, hooks_dir = sys.argv[1], sys.argv[2]

with open(hooks_file) as f:
    data = json.load(f)

hooks = data.get("hooks", {})
for sec in list(hooks.keys()):
    filtered = [h for h in hooks[sec] if hooks_dir not in json.dumps(h)]
    if filtered:
        hooks[sec] = filtered
    else:
        del hooks[sec]

with open(hooks_file, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ Codex hook 제거 완료"
}

# ── OpenCode ───────────────────────────────────────────────
# 설정 파일: ~/.config/opencode/opencode.json
# hook 포맷: {"hook": {"session_completed": [{"command": ["path"]}]}}
# 이벤트 매핑:
#   session_completed → Stop (응답 완료 후 TTS)

install_opencode() {
  local config="$HOME/.config/opencode/opencode.json"
  if [[ ! -f "$config" ]]; then
    mkdir -p "$(dirname "$config")"
    echo '{}' > "$config"
  fi

  python3 - "$config" "$HOOKS_DIR" << 'PYEOF'
import json, sys

config_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(config_path) as f:
    data = json.load(f)

if "hook" not in data:
    data["hook"] = {}

stop_cmd = [hooks_dir + "/stop.sh"]

completed = data["hook"].get("session_completed", [])
if not any(e.get("command") == stop_cmd for e in completed):
    completed.append({"command": stop_cmd})
data["hook"]["session_completed"] = completed

with open(config_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ OpenCode — 1종 hook 등록 완료"
  echo "    파일: $HOME/.config/opencode/opencode.json"
  echo "    매핑: session_completed → stop.sh"
}

uninstall_opencode() {
  local config="$HOME/.config/opencode/opencode.json"
  [[ -f "$config" ]] || { echo "  ~/.config/opencode/opencode.json 없음, 건너뜀"; return; }

  python3 - "$config" "$HOOKS_DIR" << 'PYEOF'
import json, sys

config_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(config_path) as f:
    data = json.load(f)

hook = data.get("hook", {})
for event in list(hook.keys()):
    filtered = [e for e in hook[event] if hooks_dir not in json.dumps(e)]
    if filtered:
        hook[event] = filtered
    else:
        del hook[event]

if not hook:
    data.pop("hook", None)

with open(config_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  ✓ OpenCode hook 제거 완료"
}

# ── 메인 ──────────────────────────────────────────────────

if $UNINSTALL; then
  echo "hook 제거 중: ${TOOLS[*]}"
  for tool in "${TOOLS[@]}"; do
    case "$tool" in
      claude)   uninstall_claude ;;
      codex)    uninstall_codex ;;
      opencode) uninstall_opencode ;;
    esac
  done
else
  echo "hook 등록 중: ${TOOLS[*]}"
  for tool in "${TOOLS[@]}"; do
    case "$tool" in
      claude)   install_claude ;;
      codex)    install_codex ;;
      opencode) install_opencode ;;
    esac
  done
fi

echo ""
echo "✓ 완료"
