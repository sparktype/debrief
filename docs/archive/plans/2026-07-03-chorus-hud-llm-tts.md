# chorus HUD 연동 + LLM TTS 보조 기능 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** chorus를 Claude Code statusline/HUD에 연결하고, TTS를 단순 응답 낭독에서 LLM 기반 작업 보조 레이어로 확장한다. 사용자는 현재 음성 상태, 큐, STT, 실패/위험 신호, 추천 모드를 HUD에서 즉시 보고, 중요한 이벤트는 짧고 맥락 있는 음성 브리핑으로 듣는다.

**Architecture:**
- `python -m hook_voice hud-label` — `claude-hud --extra-cmd`가 소비할 `{"label": "..."}` JSON 출력
- `GET /chorus/hud` — HUD/외부 도구용 통합 상태 API
- `~/.local/share/chorus/hud.json` — statusline이 매 2초 읽어도 부담 없는 캐시 스냅샷
- `hook_voice/assist/briefing.py` — LLM 기반 응답 브리핑, 실패 해설, 위험 해설
- `hook_voice/assist/recommend.py` — 프롬프트 의도 기반 모드/스킬 추천
- `hook_voice/hook_handlers.py` — Stop/PostToolUse/PreToolUse/UserPromptSubmit에서 보조 기능 호출
- `tts_server/server.py` — `/chorus/hud`, `/chorus/assist/*` API 노출

**Tech Stack:** Python 3.12+, FastAPI, httpx, pytest-asyncio, Claude Code statusLine, claude-hud `--extra-cmd`

## Current Evidence

- `~/.claude/settings.json`은 `statusLine.command`로 `node /Users/spark/.claude/hud/claudenews-hud.mjs`를 실행하고 `refreshInterval: 2`를 사용한다.
- `claude-hud`는 statusline 플러그인으로 stdin JSON, transcript, config를 읽고 context/tools/agents/todos를 렌더링한다.
- `claude-hud`는 `--extra-cmd`를 지원하며, extra command는 `{"label": "..."}` JSON을 반환해야 한다. label은 50자로 truncate된다.
- `claudenews` HUD는 `~/.claudenews/config.json`의 `parentStatusLine`을 실행해 기존 HUD 출력을 prepend할 수 있다.
- chorus는 이미 `/health`, `/playback/status`, `/stt/status`, `/metrics/json`, `/chorus/setup`, `/chorus/mute`, `/chorus/mode`, `/chorus/voice` API를 제공한다.
- `hook_voice/learning/advisor.py`와 `suggest-config`는 사용 통계 기반 설정 추천을 이미 갖고 있으나, HUD/대화형 노출은 아직 없다.
- `hook_voice/skill_recommender.py`는 transcript + prompt 기반 LLM 스킬 추천을 수행하지만 현재 hook 경로에서는 추천을 저장만 하고 사용자에게 적극 노출하지 않는다.

## Global Constraints

- Python `.venv/bin/python` 사용
- 테스트: `.venv/bin/pytest tests/ tts_server/test_server.py --tb=short -q`
- statusline 호출은 2초 주기로 반복되므로 네트워크/LLM 호출 금지. HUD label은 로컬 파일 또는 localhost API만 읽는다.
- HUD label은 50자 이내를 목표로 한다. 세부 정보는 `/chorus/hud` JSON에 보관한다.
- TTS 실패가 Claude Code 작업을 막으면 안 된다. 모든 보조 기능은 fail-open, timeout, fallback 필요.
- LLM 보조 기능은 자동 명령 실행 또는 설정 변경을 하지 않는다. 제안은 HUD/TTS/추가 컨텍스트로만 표시한다.
- 민감 정보는 HUD/TTS에 노출하지 않는다. token, URL query, credential-like 문자열은 redact한다.
- `.voice.json` 신규 키는 하위 호환되게 선택 필드로 추가한다.
- 경어체 발화 규칙 유지.

## Proposed Config

`.voice.json` optional fields:

```json
{
  "hud": {
    "enabled": true,
    "snapshotPath": "~/.local/share/chorus/hud.json",
    "labelMaxChars": 50,
    "showQueue": true,
    "showStt": true,
    "showMode": true,
    "showLastRisk": true
  },
  "assistantTts": {
    "enabled": true,
    "briefingMode": "smart",
    "failureExplain": true,
    "riskExplain": true,
    "promptAdvice": true,
    "maxSpokenSeconds": 12,
    "llmTimeoutMs": 2500
  }
}
```

## HUD Label Contract

`python -m hook_voice hud-label`:

```json
{"label":"chorus on | focus | q2 | STT rec | risk"}
```

`GET /chorus/hud`:

```json
{
  "label": "chorus on | focus | q2 | STT rec",
  "severity": "ok",
  "auto_speak": true,
  "voice_mode": "focus",
  "queue_depth": 2,
  "is_playing": true,
  "stt_state": "recording",
  "dlq_pending": 0,
  "last_event": {
    "kind": "briefing",
    "summary": "테스트 실패 원인 후보 1건",
    "ts": 1783072800.123
  },
  "suggestion": {
    "kind": "mode",
    "value": "quiet",
    "reason": "최근 중단율이 높습니다."
  }
}
```

## Task 1: HUD Snapshot Store

**Files:**
- Create: `hook_voice/hud/__init__.py`
- Create: `hook_voice/hud/snapshot.py`
- Create: `tests/hud/test_snapshot.py`
- Modify: `hook_voice/config.py`

**Interfaces:**
- `HudSnapshot` dataclass or typed dict
- `load_snapshot(path: Path | None = None) -> dict`
- `save_snapshot(snapshot: dict, path: Path | None = None) -> None`
- `build_label(snapshot: dict, max_chars: int = 50) -> str`

- [ ] Add config dataclass `HudConfig`.
- [ ] Implement JSON read/write with atomic replace.
- [ ] Redact suspicious secret-like values before saving.
- [ ] Unit-test missing file, malformed JSON, label truncation, redaction.

**Acceptance Criteria:**
- Missing snapshot returns safe defaults.
- Malformed snapshot never raises in statusline path.
- `build_label()` always returns <= configured max chars.
- Snapshot write is atomic and creates parent directories.

## Task 2: `/chorus/hud` API

**Files:**
- Modify: `tts_server/server.py`
- Test: `tts_server/test_server.py`

**Implementation:**
- Compose data from existing `/health`, `/playback/status`, `/stt/status`, `/metrics/json`, and `load_config()`.
- Prefer in-process data over HTTP self-calls.
- Include `label`, `severity`, `auto_speak`, `voice_mode`, `queue_depth`, `is_playing`, `stt_state`, `dlq_pending`, `last_event`, `suggestion`.

- [ ] Add `HudResponse` Pydantic model.
- [ ] Add `GET /chorus/hud`.
- [ ] Persist the same response to `hud.json` opportunistically.
- [ ] Add tests for normal, server-not-playing, STT-disabled, DLQ-pending states.

**Acceptance Criteria:**
- Endpoint returns 200 with stable fields when TTS model is still loading.
- Endpoint does not trigger LLM/TTS generation.
- `label` is safe for `claude-hud --extra-cmd`.

## Task 3: `hook_voice hud-label` CLI

**Files:**
- Modify: `hook_voice/__main__.py`
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/test_main.py`
- Test: `tests/hud/test_hud_label.py`

**Implementation:**
- Try `http://127.0.0.1:7777/chorus/hud` with timeout <= 250ms.
- On timeout/failure, read `~/.local/share/chorus/hud.json`.
- On failure again, output `{"label":"chorus offline"}`.

- [ ] Add `handle_hud_label(config)`.
- [ ] Register `hud-label` subcommand.
- [ ] Ensure stdout is exactly one JSON object.
- [ ] Add tests for API success, API timeout fallback, empty fallback.

**Acceptance Criteria:**
- Command completes under 300ms when server is unavailable.
- Output parses as JSON and has a string `label`.
- No stderr noise in normal operation.

## Task 4: claude-hud Integration Setup

**Files:**
- Create: `.claude/skills/chorus-hud/SKILL.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Recommended statusline command:**

```bash
node /Users/spark/.claude/plugins/cache/claude-hud/claude-hud/0.1.0/dist/index.js \
  --extra-cmd "cd /Users/spark/Develop/Workspaces/chorus && .venv/bin/python -m hook_voice hud-label"
```

**If claudenews remains the active outer HUD:**

`~/.claudenews/config.json`:

```json
{
  "parentStatusLine": "node /Users/spark/.claude/plugins/cache/claude-hud/claude-hud/0.1.0/dist/index.js --extra-cmd \"cd /Users/spark/Develop/Workspaces/chorus && .venv/bin/python -m hook_voice hud-label\""
}
```

- [ ] Add `/chorus-hud` or `/chorus:hud` skill that checks current statusline and prints exact next command.
- [ ] Document both direct `claude-hud` and `claudenews parentStatusLine` paths.
- [ ] Add troubleshooting section for stale labels and server offline.

**Acceptance Criteria:**
- User can enable HUD label without editing Python code.
- Existing `claudenews` statusline can stay active.
- Documentation states that statusline path must avoid LLM/network calls.

## Task 5: LLM Response Briefing

**Files:**
- Create: `hook_voice/assist/__init__.py`
- Create: `hook_voice/assist/briefing.py`
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/assist/test_briefing.py`
- Test: `tests/test_hook_handlers.py`

**Interface:**
- `brief_assistant_response(text: str, mode: str, model: str) -> Briefing`
- `Briefing(spoken_text, hud_summary, category, confidence)`

**Behavior:**
- For normal assistant responses, generate a 10-12 second spoken briefing:
  - conclusion
  - changed files or actions
  - validation evidence
  - next action or blocker
- For code-heavy responses, keep existing `summarize_with_code_hint()` fallback.
- If LLM fails or times out, use current `extract_summary()` path.

- [ ] Add prompt with strict Korean output and no markdown.
- [ ] Add timeout wrapper around LLM call.
- [ ] Save `last_event.kind = "briefing"` to HUD snapshot.
- [ ] Route spoken text through existing speech pipeline.

**Acceptance Criteria:**
- Briefing never speaks raw code blocks.
- LLM timeout falls back without delaying hook more than configured timeout.
- HUD snapshot records category and summary.

## Task 6: LLM Failure Explanation

**Files:**
- Modify: `hook_voice/assist/briefing.py`
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/assist/test_failure_explain.py`
- Test: `tests/test_hook_handlers.py`

**Behavior:**
- In `PostToolUse Bash`, when build/test commands fail, summarize:
  - failed command type
  - most relevant error line
  - likely cause
  - next local check
- Only send bounded output to LLM: command + exit code + last N relevant lines.
- Redact secrets before LLM call.

- [ ] Add `explain_command_failure(cmd, output, exit_code, model)`.
- [ ] Use regex pre-filter to avoid LLM for successful commands.
- [ ] Add config flag `assistantTts.failureExplain`.
- [ ] Save `last_event.kind = "failure"` to HUD snapshot.

**Acceptance Criteria:**
- Failed pytest/build command produces one concise spoken explanation.
- Successful commands still use existing lightweight rule path.
- Secrets and long logs are not spoken or sent to LLM.

## Task 7: LLM Risk Explanation for PreToolUse

**Files:**
- Modify: `hook_voice/assist/briefing.py`
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/assist/test_risk_explain.py`

**Behavior:**
- For destructive, install, network, credential, or production-like commands, speak a short risk explanation.
- For low-risk commands, keep existing regex messages or silence.

- [ ] Add `explain_command_risk(cmd, model)`.
- [ ] Add max 1 sentence output.
- [ ] Add cooldown to avoid repeated warnings for same command family.
- [ ] Save `last_event.kind = "risk"` to HUD snapshot.

**Acceptance Criteria:**
- `rm -rf`, `git reset --hard`, install commands, and curl-to-shell are classified.
- Low-risk read commands do not trigger LLM.
- Risk explanation does not block Claude Code tool execution.

## Task 8: Prompt Advice + Mode Recommendation

**Files:**
- Create: `hook_voice/assist/recommend.py`
- Modify: `hook_voice/hook_handlers.py`
- Modify: `hook_voice/learning/advisor.py`
- Test: `tests/assist/test_recommend.py`

**Behavior:**
- On `UserPromptSubmit`, infer whether the prompt is analysis, implementation, review, long planning, debugging, or cleanup.
- Recommend `voiceMode` and optional skill:
  - analysis/review/long planning -> `focus`
  - repeated failures/noisy session -> `quiet`
  - short interactive setup -> `verbose`
- Surface recommendation through HUD snapshot and optional additional context, not automatic config mutation.

- [ ] Add `recommend_prompt_assist(prompt, transcript_context, stats)`.
- [ ] Merge with existing `skill_recommender` result.
- [ ] Save recommendation in HUD snapshot.
- [ ] Add cooldown by recommendation key.

**Acceptance Criteria:**
- Prompt advice appears in HUD within the next statusline refresh.
- Repeated same suggestion is suppressed by cooldown.
- No config file is changed automatically.

## Task 9: Session Digest Audio

**Files:**
- Modify: `hook_voice/last_message.py`
- Modify: `hook_voice/hook_handlers.py`
- Create: `.claude/skills/chorus-digest/SKILL.md`
- Test: `tests/test_last_message.py`

**Behavior:**
- Add manual command `python -m hook_voice digest [--last N]`.
- Read recent assistant/subagent summaries and produce:
  - completed work
  - unresolved blockers
  - failed checks
  - recommended next step
- Speak with reviewer/planner voice when available.

**Acceptance Criteria:**
- Digest can be run manually without active Claude hook payload.
- Digest does not include raw secrets or long code.
- If there is no history, it prints and optionally speaks a short empty-state message.

## Task 10: Documentation and Onboarding

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `ONBOARDING.md`
- Create: `docs/superpowers/specs/2026-07-03-chorus-hud-llm-tts-design.md` if deeper design is needed.

- [ ] Add HUD setup section.
- [ ] Add "TTS assistant modes" section.
- [ ] Add privacy and data-flow section: what is local, what goes to LLM.
- [ ] Add troubleshooting commands:
  - `.venv/bin/python -m hook_voice hud-label`
  - `curl -s localhost:7777/chorus/hud`
  - `curl -s localhost:7777/playback/status`
  - `.venv/bin/python -m hook_voice privacy status`

**Acceptance Criteria:**
- A new user can understand how HUD, TTS, STT, and LLM assistance interact.
- Docs distinguish "shown in HUD" from "spoken by TTS".
- Docs state that LLM assistance is opt-in/configurable and never auto-applies changes.

## Verification Plan

Run after each implementation slice:

```bash
.venv/bin/pytest tests/hud tests/assist tests/test_hook_handlers.py tests/test_main.py -v --tb=short
```

Run before merge:

```bash
.venv/bin/pytest tests/ tts_server/test_server.py --tb=short -q
.venv/bin/python -m hook_voice hud-label
curl -s http://127.0.0.1:7777/chorus/hud
git diff --check
```

Manual verification:

- Start server: `./server.sh start`
- Confirm HUD label updates when toggling mute: `.venv/bin/python -m hook_voice mute`
- Confirm HUD label updates when STT recording starts/stops: `./hooks/listen.sh`
- Trigger a failing test command and confirm failure explanation is concise.
- Confirm `claudenews` still renders if used as outer statusline.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| statusline becomes slow | Claude Code UI feels laggy | HUD path reads local snapshot first, localhost timeout <= 250ms, no LLM in statusline |
| noisy TTS | User mutes chorus | Add mode-aware gating, cooldown, max spoken seconds |
| LLM leaks secrets from logs | Security issue | Redact before LLM/TTS/HUD, bounded log extraction |
| HUD label too long | claude-hud truncates awkwardly | `build_label()` width/char limit tests |
| duplicate recommendations | Annoyance | cooldown by recommendation key |
| server unavailable | broken HUD label | `hud-label` falls back to snapshot then `chorus offline` |

## ADR

**Decision:** Use chorus as a local status provider for `claude-hud` through a small `hud-label` command and `/chorus/hud` API, while keeping LLM analysis outside the statusline refresh path.

**Drivers:**
- Claude Code statusline refresh is frequent and must stay fast.
- chorus already owns TTS/STT/playback state and local usage stats.
- LLM-based value is highest for summarizing events, failures, risks, and recommendations, not for polling UI.

**Alternatives considered:**
- Patch `claude-hud` render code directly. Rejected because plugin updates would overwrite changes and create maintenance coupling.
- Replace current `claudenews` statusline. Rejected because `claudenews` already supports `parentStatusLine`, so composition is safer.
- Put all state in FastAPI only. Rejected because statusline should still work when server is down.

**Why chosen:** `--extra-cmd` is a narrow supported extension point, and a local snapshot makes the integration reliable under server/LLM failure.

**Consequences:**
- Adds a small HUD state module to chorus.
- Requires documentation for one statusline command or `claudenews` parentStatusLine config.
- Keeps implementation reversible and avoids forking HUD plugins.

**Follow-ups:**
- Add a small `/chorus:hud` Claude skill to install/check the integration.
- Add a dashboard view later if `/chorus/hud` proves useful beyond statusline.
- Consider MCP tool wrappers only after the local API/CLI contract stabilizes.

## Suggested Execution Order

1. Task 1-3: HUD snapshot, API, `hud-label` CLI.
2. Task 4: claude-hud/claudenews setup docs and skill.
3. Task 5-7: LLM briefing, failure explanation, risk explanation.
4. Task 8: prompt advice and mode recommendation.
5. Task 9-10: digest command and docs/onboarding polish.

## Commit Strategy

- `feat: add chorus HUD snapshot and hud-label command`
- `feat: expose chorus HUD status API`
- `docs: document claude-hud integration for chorus`
- `feat: add LLM briefing for TTS assistant mode`
- `feat: explain command failures and risks via assistant TTS`
- `feat: add prompt advice and session digest for chorus`

