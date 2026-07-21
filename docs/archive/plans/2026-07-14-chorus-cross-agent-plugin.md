# Chorus Cross-Agent Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Chorus as one path-independent, privacy-safe plugin for Claude Code and Codex with guided setup, shared commands, reliable hooks, diagnostics, and legacy migration.

**Architecture:** Keep the existing Python speech and TTS implementation as the runtime core, add a provider-neutral `HookEvent` adapter at its boundary, and deliver raw hook payloads to the loopback daemon through a bounded standard-library runner. Package the same runtime, hooks, scripts, and skills behind dual Claude/Codex manifests; install immutable runtime releases beneath `~/.local/share/chorus/runtime` and keep mutable data outside releases.

**Tech Stack:** Python 3.11+, shell scripts, FastAPI/httpx already used by the repository, macOS launchd, Claude Code plugin manifests, Codex plugin manifests, pytest.

## Global Constraints

- Runtime support remains macOS Apple Silicon only.
- Do not add a dependency solely for installation or hook transport.
- The only LaunchAgent label is `io.chorus.server`.
- Hooks must fail open, exit zero, and use a bounded loopback delivery timeout.
- Before setup, `configured=false`, `autoSpeak=false`, `usageTracking=false`, and all external LLM features are disabled.
- Runtime upgrades stage and validate a release before atomically changing `runtime/current`.
- Preserve configuration, state, statistics, models, and logs on ordinary uninstall; remove them only with an explicit purge.
- Tests use an isolated temporary `HOME` and do not require network, microphone, audio output, or a live coding agent.

## File Structure

- `hook_voice/event/hook_event.py`: immutable provider-neutral hook input and Claude/Codex payload adapters.
- `hook_voice/runtime_paths.py`: stable data/release/config paths and atomic JSON writes.
- `hook_voice/runtime_manager.py`: install, upgrade, rollback, LaunchAgent, migration, status, and doctor operations.
- `hook_voice/hook_dispatch.py`: canonical-event dispatch into the existing speech handlers.
- `tts_server/server.py`: loopback hook ingestion and management endpoints.
- `plugins/chorus/`: distributable dual-manifest plugin package with shared hooks, scripts, skills, runtime payload, and assets.
- `.agents/plugins/marketplace.json`: Codex marketplace entry.
- `.claude-plugin/marketplace.json`: Claude marketplace entry.
- `tests/plugin/`: schemas, hook runner, adapters, installer, privacy, skills, diagnostics, and migration regression tests.
- `setup-tts.sh`, `server.sh`, `install.sh`, `uninstall.sh`: compatibility wrappers over the stable runtime manager.
- `README.md`, `ONBOARDING.md`: plugin-first installation and recovery documentation.

---

### Task 1: Stable Runtime Paths and Inert Privacy Defaults

**Files:**
- Create: `hook_voice/runtime_paths.py`
- Modify: `hook_voice/config.py`
- Test: `tests/plugin/test_runtime_paths.py`
- Test: `tests/plugin/test_privacy_defaults.py`

**Interfaces:**
- Produces: `RuntimePaths.from_environment(env: Mapping[str, str] | None = None) -> RuntimePaths`
- Produces: `atomic_write_json(path: Path, value: Mapping[str, object]) -> None`
- Produces: `Config.configured`, `Config.privacy_preset`, and inert default capability flags.

- [ ] **Step 1: Write failing isolated-path and default-privacy tests**

```python
def test_runtime_paths_are_stable_outside_plugin_cache(tmp_path):
    paths = RuntimePaths.from_environment({"HOME": str(tmp_path), "PLUGIN_ROOT": "/cache/v2"})
    assert paths.data_dir == tmp_path / ".local/share/chorus"
    assert paths.current == paths.data_dir / "runtime/current"

def test_unconfigured_defaults_have_no_side_effect_capabilities():
    config = load_config(Path("/missing/config.json"))
    assert config.configured is False
    assert config.auto_speak is False
    assert config.usage_tracking is False
    assert config.assistant_tts.enabled is False
```

- [ ] **Step 2: Run the tests and confirm current defaults fail**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_runtime_paths.py tests/plugin/test_privacy_defaults.py -q`

Expected: failures for the missing module and currently enabled default capabilities.

- [ ] **Step 3: Implement stable paths, atomic JSON writes, and explicit setup state**

```python
@dataclass(frozen=True)
class RuntimePaths:
    data_dir: Path
    runtime_dir: Path
    releases: Path
    current: Path
    config: Path
    state: Path
    logs: Path

    @classmethod
    def from_environment(cls, env=None):
        values = os.environ if env is None else env
        root = Path(values.get("CHORUS_DATA_DIR", Path(values["HOME"]) / ".local/share/chorus"))
        return cls(root, root / "runtime", root / "runtime/releases", root / "runtime/current", root / "config.json", root / "state.json", root / "logs")

def atomic_write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)
```

Add `configured: bool = False`, `privacy_preset: str | None = None`, change `auto_speak` and `usage_tracking` to `False`, and change `AssistantTtsConfig.enabled` plus its external-advice flags to `False`. Extend key mapping and validation so explicit migrated values still load.

- [ ] **Step 4: Run targeted config and privacy tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/test_config.py tests/plugin/test_runtime_paths.py tests/plugin/test_privacy_defaults.py -q`

Expected: all tests pass; existing tests that intentionally asserted old defaults are updated to assert inert first-run behavior.

- [ ] **Step 5: Commit the privacy foundation**

```bash
git add hook_voice/config.py hook_voice/runtime_paths.py tests/test_config.py tests/plugin/test_runtime_paths.py tests/plugin/test_privacy_defaults.py
git commit -m "feat: make chorus runtime privacy-safe by default"
```

### Task 2: Provider-Neutral Hook Event Adapter

**Files:**
- Create: `hook_voice/event/hook_event.py`
- Create: `tests/plugin/fixtures/claude_hooks.json`
- Create: `tests/plugin/fixtures/codex_hooks.json`
- Create: `tests/plugin/test_hook_event.py`
- Modify: `hook_voice/hook_handlers.py`

**Interfaces:**
- Consumes: `RuntimePaths` from Task 1 for fallback transcript and state locations.
- Produces: frozen `HookEvent` with the exact fields in the approved design.
- Produces: `adapt_hook_payload(payload, *, source, event_name, env=None) -> HookEvent`.

- [ ] **Step 1: Add Claude and Codex fixtures for all shared events**

```json
{
  "Stop": {"session_id": "claude-s1", "cwd": "/work", "transcript_path": "/tmp/c.jsonl", "last_assistant_message": "완료했습니다."},
  "PreToolUse": {"session_id": "claude-s1", "tool_name": "Bash", "tool_input": {"command": "pytest -q"}}
}
```

The Codex fixture uses its native session/turn/agent keys and includes Stop, SubagentStop, PreToolUse, PostToolUse, UserPromptSubmit, and SessionStart entries.

- [ ] **Step 2: Write table-driven precedence and normalization tests**

```python
@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_stop_payload_normalizes(provider, fixture_payloads):
    event = adapt_hook_payload(fixture_payloads[provider]["Stop"], source=provider, event_name="Stop", env={"CLAUDE_CODE_SESSION_ID": "fallback"})
    assert event.source == provider
    assert event.event_name == "Stop"
    assert event.session_id != "fallback"
    assert event.assistant_message
```

- [ ] **Step 3: Verify the adapter tests fail**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_hook_event.py -q`

Expected: import failure for `HookEvent` and `adapt_hook_payload`.

- [ ] **Step 4: Implement the immutable event and provider key aliases**

```python
@dataclass(frozen=True)
class HookEvent:
    source: Literal["claude", "codex", "opencode", "unknown"]
    event_name: str
    session_id: str
    cwd: Path | None
    transcript_path: Path | None
    turn_id: str | None
    agent_id: str | None
    agent_type: str | None
    assistant_message: str | None
    tool_name: str | None
    tool_input: Mapping[str, object]
    tool_response: Mapping[str, object]
    raw: Mapping[str, object]
```

Use payload keys first and environment variables only as compatibility fallbacks. Replace `_derive_transcript_path()` call sites with data from `HookEvent`; keep a temporary fallback inside the adapter for legacy Claude payloads.

- [ ] **Step 5: Run adapter and existing hook-handler tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_hook_event.py tests/test_hook_handlers.py -q`

Expected: all pass for both provider fixtures and legacy handler behavior.

- [ ] **Step 6: Commit the adapter boundary**

```bash
git add hook_voice/event/hook_event.py hook_voice/hook_handlers.py tests/plugin/fixtures tests/plugin/test_hook_event.py tests/test_hook_handlers.py
git commit -m "feat: normalize Claude and Codex hook events"
```

### Task 3: Fast Fail-Open Hook Delivery and Daemon Ingestion

**Files:**
- Create: `plugins/chorus/scripts/chorus-hook`
- Create: `hook_voice/hook_dispatch.py`
- Modify: `tts_server/server.py`
- Test: `tests/plugin/test_hook_runner.py`
- Test: `tests/plugin/test_hook_ingest.py`

**Interfaces:**
- Consumes: `adapt_hook_payload()` from Task 2.
- Produces: `POST /hooks/events` accepting `{source, event_name, payload}`.
- Produces: `dispatch_hook_event(event: HookEvent, config: Config) -> Awaitable[None]`.
- Writes: `last_hook_delivery_error.json` and per-source success records under the stable data directory.

- [ ] **Step 1: Write runner tests for movable roots, timeout, atomic error state, and exit zero**

```python
def test_hook_runner_fails_open_and_records_error(tmp_path, run_hook):
    result = run_hook(tmp_path, stdin='{"session_id":"s1"}', env={"CHORUS_HOOK_EVENT": "Stop", "CHORUS_HOOK_SOURCE": "codex", "CHORUS_HOOK_URL": "http://127.0.0.1:9/hooks/events"})
    assert result.returncode == 0
    error = json.loads((tmp_path / ".local/share/chorus/last_hook_delivery_error.json").read_text())
    assert error["source"] == "codex"
```

- [ ] **Step 2: Write ingestion tests proving unconfigured requests do not dispatch speech**

```python
def test_hook_ingest_is_inert_before_setup(client, monkeypatch):
    called = False
    monkeypatch.setattr("tts_server.server.dispatch_hook_event", lambda *args: setattr_nonlocal("called", True))
    response = client.post("/hooks/events", json={"source": "claude", "event_name": "Stop", "payload": {}})
    assert response.status_code == 202
    assert called is False
```

- [ ] **Step 3: Run both tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_hook_runner.py tests/plugin/test_hook_ingest.py -q`

Expected: missing script and endpoint failures.

- [ ] **Step 4: Implement the standard-library hook runner**

```python
#!/usr/bin/env python3
body = json.dumps({"source": source, "event_name": event_name, "payload": json.loads(sys.stdin.read() or "{}")}).encode()
request = urllib.request.Request(url, body, {"Content-Type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(request, timeout=0.35).read()
except Exception as exc:
    atomic_error_write(data_dir / "last_hook_delivery_error.json", source, event_name, exc)
raise SystemExit(0)
```

The script resolves data from `CLAUDE_PLUGIN_DATA`, `PLUGIN_DATA`, `CHORUS_DATA_DIR`, then `~/.local/share/chorus`; it never imports project runtime modules.

- [ ] **Step 5: Add ingestion and canonical dispatch**

```python
@app.post("/hooks/events", status_code=202)
async def ingest_hook(request: HookRequest):
    config = load_config(RuntimePaths.from_environment().config)
    if not config.configured:
        return {"accepted": True, "active": False}
    event = adapt_hook_payload(request.payload, source=request.source, event_name=request.event_name)
    asyncio.create_task(dispatch_hook_event(event, config))
    record_hook_success(event.source, event.event_name)
    return {"accepted": True, "active": True}
```

Map only canonical fields into existing Stop, SubagentStop, Bash pre/post, prompt, and session handlers.

- [ ] **Step 6: Run runner, ingest, and server tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_hook_runner.py tests/plugin/test_hook_ingest.py tts_server/test_server.py -q`

Expected: all pass without audio/model/network use.

- [ ] **Step 7: Commit hook delivery**

```bash
git add plugins/chorus/scripts/chorus-hook hook_voice/hook_dispatch.py tts_server/server.py tests/plugin/test_hook_runner.py tests/plugin/test_hook_ingest.py
git commit -m "feat: deliver hooks through the local chorus daemon"
```

### Task 4: Transactional Runtime Installer and LaunchAgent Migration

**Files:**
- Create: `hook_voice/runtime_manager.py`
- Create: `plugins/chorus/scripts/chorus-runtime`
- Test: `tests/plugin/test_runtime_manager.py`
- Test: `tests/plugin/test_launchagent_migration.py`

**Interfaces:**
- Consumes: `RuntimePaths` and atomic JSON operations from Task 1.
- Produces: `install_release(source: Path, version: str, paths: RuntimePaths) -> InstallResult`.
- Produces: `render_launchagent(paths: RuntimePaths, python: Path) -> str`.
- Produces CLI: `chorus-runtime install|start|stop|restart|status|doctor|setup|mute|listen|mode|digest|uninstall`.

- [ ] **Step 1: Write installer transaction tests**

```python
def test_failed_release_validation_keeps_previous_current(tmp_path, monkeypatch):
    paths = make_paths(tmp_path)
    old = seed_release(paths, "1.0.0")
    monkeypatch.setattr("hook_voice.runtime_manager.validate_release", lambda _: (_ for _ in ()).throw(ReleaseValidationError("bad import")))
    with pytest.raises(ReleaseValidationError):
        install_release(Path("fixture"), "2.0.0", paths)
    assert paths.current.resolve() == old
```

- [ ] **Step 2: Write duplicate LaunchAgent migration tests**

```python
def test_legacy_agent_is_removed_only_after_new_health_check(tmp_path, fake_launchctl):
    fake_launchctl.health_ok = False
    result = migrate_launchagents(make_paths(tmp_path), fake_launchctl)
    assert result.legacy_removed is False
    fake_launchctl.health_ok = True
    result = migrate_launchagents(make_paths(tmp_path), fake_launchctl)
    assert result.legacy_removed is True
```

- [ ] **Step 3: Run installer tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_runtime_manager.py tests/plugin/test_launchagent_migration.py -q`

Expected: missing runtime manager failures.

- [ ] **Step 4: Implement staged copy, validation, and atomic symlink switch**

```python
def install_release(source, version, paths):
    staging = paths.releases / f".{version}.{uuid.uuid4().hex}.staging"
    destination = paths.releases / version
    shutil.copytree(source, staging)
    validate_release(staging)
    os.replace(staging, destination)
    next_link = paths.runtime_dir / ".current.next"
    next_link.symlink_to(destination)
    os.replace(next_link, paths.current)
    return InstallResult(version=version, release=destination)
```

Validation imports `hook_voice` and `tts_server.server`, runs `chorus-hook` against an unavailable port to confirm exit zero, and checks the runtime manifest.

- [ ] **Step 5: Implement stable LaunchAgent and safe legacy removal**

```xml
<key>Label</key><string>io.chorus.server</string>
<key>ProgramArguments</key>
<array><string>__PYTHON__</string><string>-m</string><string>tts_server.supervisor</string></array>
<key>WorkingDirectory</key><string>__CURRENT__</string>
<key>StandardOutPath</key><string>__LOG__</string>
```

The manager bootstraps and health-checks `io.chorus.server` before booting out and deleting `com.voice-persona.tts-server.plist`.

- [ ] **Step 6: Implement `chorus-runtime` as a location-independent wrapper**

```bash
#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="${CHORUS_DATA_DIR:-$HOME/.local/share/chorus}"
exec "$DATA_DIR/runtime/current/.venv/bin/python" -m hook_voice.runtime_manager "$@"
```

For the initial `install` command, fall back to `/usr/bin/python3` and `PLUGIN_ROOT/runtime` before `current` exists.

- [ ] **Step 7: Run installer and launchd tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_runtime_manager.py tests/plugin/test_launchagent_migration.py -q`

Expected: first install, idempotent reinstall, update, rollback, preserved data, and gated legacy removal all pass.

- [ ] **Step 8: Commit runtime management**

```bash
git add hook_voice/runtime_manager.py plugins/chorus/scripts/chorus-runtime tests/plugin/test_runtime_manager.py tests/plugin/test_launchagent_migration.py
git commit -m "feat: install chorus runtime transactionally"
```

### Task 5: Guided Setup, Privacy Presets, and Management Diagnostics

**Files:**
- Modify: `hook_voice/runtime_manager.py`
- Modify: `hook_voice/hook_handlers.py`
- Modify: `hook_voice/__main__.py`
- Test: `tests/plugin/test_setup.py`
- Test: `tests/plugin/test_status_doctor.py`

**Interfaces:**
- Produces: `apply_privacy_preset(name: Literal["local", "standard", "detailed"], config_path: Path) -> Config`.
- Produces: `collect_status(paths: RuntimePaths) -> StatusReport` and `run_doctor(paths: RuntimePaths, audible: bool = False) -> DoctorReport`.
- CLI returns human-readable text by default and JSON with `--json`.

- [ ] **Step 1: Write exact preset tests**

```python
@pytest.mark.parametrize(("preset", "external", "tracking", "tool_events"), [
    ("local", False, False, "failures"),
    ("standard", True, False, "failures"),
    ("detailed", True, True, "build_test_risk_failure"),
])
def test_privacy_presets(preset, external, tracking, tool_events, tmp_path):
    config = apply_privacy_preset(preset, tmp_path / "config.json")
    assert config.configured and config.auto_speak
    assert config.assistant_tts.enabled is external
    assert config.usage_tracking is tracking
    assert config.tool_event_speech == tool_events
```

- [ ] **Step 2: Write status and doctor recovery-message tests**

```python
def test_doctor_reports_one_exact_recovery_command_for_stopped_daemon(tmp_path):
    report = run_doctor(make_paths(tmp_path), probes=FakeProbes(daemon=False))
    failure = next(check for check in report.checks if check.name == "daemon")
    assert failure.recovery == "chorus-runtime start"
```

- [ ] **Step 3: Run setup and diagnostics tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_setup.py tests/plugin/test_status_doctor.py -q`

Expected: missing preset/status/doctor interfaces.

- [ ] **Step 4: Implement presets and one-time legacy import**

```python
PRESETS = {
    "local": {"autoSpeak": True, "externalLlm": False, "usageTracking": False, "toolEventSpeech": "failures"},
    "standard": {"autoSpeak": True, "externalLlm": True, "externalFeatures": ["stop_summary"], "usageTracking": False, "toolEventSpeech": "failures"},
    "detailed": {"autoSpeak": True, "externalLlm": True, "externalFeatures": ["stop_summary", "failure_explain", "prompt_advice"], "usageTracking": True, "toolEventSpeech": "build_test_risk_failure"},
}
```

Import legacy values once, intersect enabled capabilities with the selected preset, save `migration.imported_legacy=true`, and display every imported or suppressed capability.

- [ ] **Step 5: Implement concise status and bounded doctor checks**

```python
checks = [
    check_runtime_release(paths), check_launchagent(), check_daemon(), check_model(),
    check_hook_delivery("claude"), check_hook_delivery("codex"), check_privacy(config),
    check_queue(), check_duplicate_agents(), check_manifests(), check_synthetic_stop(),
]
```

Status remains read-only. Doctor never invokes the external summary provider and plays audio only with `--audible`.

- [ ] **Step 6: Route existing management subcommands to the stable config path**

Update `hook_voice.__main__` so `setup`, `status`, `doctor`, `mute`, `listen`, `mode`, and `digest` consistently use `RuntimePaths.from_environment().config` instead of repository `.voice.json` unless explicitly passed `--legacy-config`.

- [ ] **Step 7: Run setup, diagnostic, and existing command tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_setup.py tests/plugin/test_status_doctor.py tests/test_main.py tests/test_hook_handlers.py -q`

Expected: all pass and no test writes outside the temporary home.

- [ ] **Step 8: Commit setup and diagnostics**

```bash
git add hook_voice/runtime_manager.py hook_voice/hook_handlers.py hook_voice/__main__.py tests/plugin/test_setup.py tests/plugin/test_status_doctor.py tests/test_main.py tests/test_hook_handlers.py
git commit -m "feat: add guided privacy setup and diagnostics"
```

### Task 6: Dual Plugin Manifests, Hook Contracts, and Marketplaces

**Files:**
- Create: `plugins/chorus/.claude-plugin/plugin.json`
- Create: `plugins/chorus/.codex-plugin/plugin.json`
- Create: `plugins/chorus/hooks/hooks.json`
- Create: `plugins/chorus/hooks/claude-hooks.json`
- Create: `plugins/chorus/runtime/manifest.json`
- Create: `.agents/plugins/marketplace.json`
- Create: `.claude-plugin/marketplace.json`
- Test: `tests/plugin/test_manifests.py`
- Test: `tests/plugin/test_hooks_manifest.py`

**Interfaces:**
- Consumes: `plugins/chorus/scripts/chorus-hook` and `chorus-runtime`.
- Produces: plugin name `chorus`, semantic version, seven shared skills, and shared six-event hook mapping.

- [ ] **Step 1: Write schema and parity tests**

```python
def test_dual_manifests_name_the_same_plugin(load_json):
    claude = load_json("plugins/chorus/.claude-plugin/plugin.json")
    codex = load_json("plugins/chorus/.codex-plugin/plugin.json")
    assert claude["name"] == codex["name"] == "chorus"

def test_shared_hooks_cover_exact_common_contract(load_json):
    hooks = load_json("plugins/chorus/hooks/hooks.json")["hooks"]
    assert set(hooks) == {"Stop", "SubagentStop", "PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart"}
```

- [ ] **Step 2: Run manifest tests and verify missing files fail**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_manifests.py tests/plugin/test_hooks_manifest.py -q`

Expected: file-not-found failures.

- [ ] **Step 3: Create minimal ecosystem manifests**

```json
{"name":"chorus","version":"1.0.0","description":"Local voice feedback for Claude Code and Codex on macOS Apple Silicon"}
```

Keep ecosystem-only metadata in its manifest. Do not add a Codex `hooks` field; default discovery uses `hooks/hooks.json`.

- [ ] **Step 4: Register shared hook commands with source and event metadata**

```json
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"CHORUS_HOOK_SOURCE=${CODEX_HOME:+codex} CHORUS_HOOK_EVENT=Stop $CLAUDE_PLUGIN_ROOT/scripts/chorus-hook","timeout":2}]}]}}
```

Use a portable wrapper command that resolves Codex `PLUGIN_ROOT` when `CLAUDE_PLUGIN_ROOT` is absent. Put Claude-only `Notification` in `claude-hooks.json` and do not claim Codex parity for it.

- [ ] **Step 5: Create both repository marketplace entries**

```json
{"plugins":[{"name":"chorus","source":"./plugins/chorus","description":"Private-by-default local voice feedback","category":"developer-tools","installation":"Run /chorus:setup after install","authentication":"Optional external summary provider credentials"}]}
```

Include macOS Apple Silicon, microphone permission for listen mode, local audio, and optional external text transmission in marketplace copy.

- [ ] **Step 6: Validate schemas and plugin manifests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_manifests.py tests/plugin/test_hooks_manifest.py -q`

Run: `python3 /Users/spark/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py plugins/chorus`

Expected: pytest passes and Codex validator reports a valid plugin. If `claude` exists, also run `claude plugin validate plugins/chorus --strict` and require success.

- [ ] **Step 7: Commit packaging metadata**

```bash
git add plugins/chorus/.claude-plugin plugins/chorus/.codex-plugin plugins/chorus/hooks plugins/chorus/runtime/manifest.json .agents/plugins/marketplace.json .claude-plugin/marketplace.json tests/plugin/test_manifests.py tests/plugin/test_hooks_manifest.py
git commit -m "feat: package chorus for Claude Code and Codex"
```

### Task 7: Shared Seven-Skill User Experience

**Files:**
- Create: `plugins/chorus/skills/setup/SKILL.md`
- Create: `plugins/chorus/skills/status/SKILL.md`
- Create: `plugins/chorus/skills/doctor/SKILL.md`
- Create: `plugins/chorus/skills/mute/SKILL.md`
- Create: `plugins/chorus/skills/listen/SKILL.md`
- Create: `plugins/chorus/skills/mode/SKILL.md`
- Create: `plugins/chorus/skills/digest/SKILL.md`
- Test: `tests/plugin/test_skill_parity.py`

**Interfaces:**
- Consumes: `chorus-runtime` management commands from Tasks 4 and 5.
- Produces: identical `/chorus:setup`, `status`, `doctor`, `mute`, `listen`, `mode`, and `digest` workflows.

- [ ] **Step 1: Write exact skill-set and stable-command tests**

```python
EXPECTED = {"setup", "status", "doctor", "mute", "listen", "mode", "digest"}

def test_plugin_exposes_exact_shared_skill_set():
    assert {p.parent.name for p in Path("plugins/chorus/skills").glob("*/SKILL.md")} == EXPECTED

def test_skills_never_reference_checkout_venv():
    bodies = "\n".join(p.read_text() for p in Path("plugins/chorus/skills").glob("*/SKILL.md"))
    assert ".venv/bin/python" not in bodies
    assert "chorus-runtime" in bodies
```

- [ ] **Step 2: Run parity tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_skill_parity.py -q`

Expected: all seven skill files are missing.

- [ ] **Step 3: Create setup, status, and doctor workflows**

```markdown
---
name: chorus:status
description: Show Chorus runtime, hook, privacy, queue, mute, and last-error status.
---

Run `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/chorus-runtime status`. Present the output unchanged. If Codex delivery is absent, include the command's `/hooks` trust guidance.
```

Setup checks platform, installs runtime, presents the three privacy presets and data-boundary copy, saves the selected preset, registers the service, verifies hooks, performs the requested voice test, and prints final status.

- [ ] **Step 4: Create mute, listen, mode, and digest workflows**

Mute accepts `global`, `session`, or `30m`; listen reports microphone/optional dependency errors; mode accepts only `normal|focus|quiet|verbose|night`; digest defaults to ten recent events and never enables tracking implicitly.

- [ ] **Step 5: Run skill parity and content tests**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_skill_parity.py -q`

Expected: exact skill set, valid frontmatter, stable runtime command, and no checkout-relative runtime path.

- [ ] **Step 6: Commit the shared workflow surface**

```bash
git add plugins/chorus/skills tests/plugin/test_skill_parity.py
git commit -m "feat: add shared chorus plugin workflows"
```

### Task 8: Runtime Payload Assembly and Legacy Compatibility Wrappers

**Files:**
- Create: `scripts/build-plugin-runtime.sh`
- Modify: `setup-tts.sh`
- Modify: `server.sh`
- Modify: `install.sh`
- Modify: `uninstall.sh`
- Modify: `hooks/stop.sh`
- Modify: `hooks/subagent-stop.sh`
- Modify: `hooks/pre-tool-bash.sh`
- Modify: `hooks/post-tool-bash.sh`
- Modify: `hooks/prompt-submit.sh`
- Modify: `hooks/session-start.sh`
- Modify: `hooks/notification.sh`
- Test: `tests/plugin/test_runtime_payload.py`
- Test: `tests/plugin/test_legacy_wrappers.py`

**Interfaces:**
- Consumes: stable runtime installer and hook runner.
- Produces: deterministic copied runtime under `plugins/chorus/runtime`.
- Preserves: old repository command names while delegating to the new implementation.

- [ ] **Step 1: Write payload completeness and absolute-path regression tests**

```python
def test_runtime_payload_contains_required_packages():
    assert (Path("plugins/chorus/runtime/hook_voice/__init__.py")).exists()
    assert (Path("plugins/chorus/runtime/tts_server/__init__.py")).exists()

def test_no_committed_hook_contains_developer_home_path():
    for path in Path("hooks").glob("*.sh"):
        assert "/Users/" not in path.read_text()
```

- [ ] **Step 2: Write wrapper delegation tests**

```python
@pytest.mark.parametrize("script", ["setup-tts.sh", "server.sh", "install.sh", "uninstall.sh"])
def test_legacy_script_announces_migration_and_delegates(script, run_script):
    result = run_script(script, env={"CHORUS_RUNTIME_BIN": "/tmp/fake-chorus-runtime"})
    assert "deprecated" in result.stderr.lower() or "마이그레이션" in result.stderr
    assert result.delegated_to_runtime
```

- [ ] **Step 3: Run payload/wrapper tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_runtime_payload.py tests/plugin/test_legacy_wrappers.py -q`

Expected: missing payload builder and hard-coded hook paths fail.

- [ ] **Step 4: Implement deterministic runtime assembly**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/plugins/chorus/runtime"
rsync -a --delete --exclude '__pycache__' "$ROOT/hook_voice" "$ROOT/tts_server" "$ROOT/assets" "$ROOT/classify-rules.json" "$ROOT/voice-map.json" "$DEST/"
```

The builder copies source and assets, not `.venv`, caches, logs, credentials, or user configuration. A second build must produce no git diff.

- [ ] **Step 5: Replace legacy scripts with thin compatibility dispatch**

```bash
RUNTIME_BIN="${CHORUS_RUNTIME_BIN:-$HOME/.local/share/chorus/runtime/current/bin/chorus-runtime}"
echo "chorus: repository installer is deprecated; using the plugin runtime" >&2
if [[ ! -x "$RUNTIME_BIN" ]]; then
  RUNTIME_BIN="$SCRIPT_DIR/plugins/chorus/scripts/chorus-runtime"
fi
exec "$RUNTIME_BIN" "$@"
```

Map `server.sh install/start/...`, setup, hook install guidance, and uninstall/purge options explicitly. Replace each legacy hook body with a source/event environment wrapper around `plugins/chorus/scripts/chorus-hook`.

- [ ] **Step 6: Build payload twice and run regression tests**

Run: `scripts/build-plugin-runtime.sh && git diff --exit-code plugins/chorus/runtime && scripts/build-plugin-runtime.sh && git diff --exit-code plugins/chorus/runtime`

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_runtime_payload.py tests/plugin/test_legacy_wrappers.py -q`

Expected: deterministic payload and all wrapper tests pass.

- [ ] **Step 7: Commit payload and migration wrappers**

```bash
git add scripts/build-plugin-runtime.sh plugins/chorus/runtime setup-tts.sh server.sh install.sh uninstall.sh hooks tests/plugin/test_runtime_payload.py tests/plugin/test_legacy_wrappers.py
git commit -m "refactor: route legacy chorus commands through plugin runtime"
```

### Task 9: Plugin-First Documentation and End-to-End Acceptance

**Files:**
- Modify: `README.md`
- Modify: `ONBOARDING.md`
- Create: `docs/plugin-migration.md`
- Create: `tests/plugin/test_documentation.py`
- Create: `tests/plugin/test_acceptance.py`

**Interfaces:**
- Documents: Claude marketplace install, Codex marketplace install, `/hooks` trust, `/chorus:setup`, privacy presets, legacy migration, status/doctor, and uninstall/purge.

- [ ] **Step 1: Write documentation contract tests**

```python
def test_readme_is_plugin_first():
    readme = Path("README.md").read_text()
    assert "/chorus:setup" in readme
    assert "/chorus:status" in readme
    assert "/hooks" in readme
    assert "local" in readme and "standard" in readme and "detailed" in readme
```

- [ ] **Step 2: Write acceptance tests for fresh install, offline hook, and update persistence**

```python
def test_fresh_local_setup_then_offline_hook(tmp_path, plugin_fixture):
    result = plugin_fixture.setup(tmp_path, preset="local", voice_test=False)
    assert result.status.configured
    assert result.status.external_llm is False
    hook = plugin_fixture.run_hook(url="http://127.0.0.1:9/hooks/events")
    assert hook.returncode == 0
    assert result.paths.last_hook_error.exists()
```

- [ ] **Step 3: Run documentation and acceptance tests and verify failure**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_documentation.py tests/plugin/test_acceptance.py -q`

Expected: plugin-first copy and/or full workflow assertions fail before documentation and fixture completion.

- [ ] **Step 4: Rewrite the quick start around plugin installation**

Document two short installation paths, then one shared flow:

```text
1. Install the chorus plugin from this repository marketplace.
2. Run /chorus:setup and choose local, standard, or detailed.
3. In Codex, review and trust the plugin hook with /hooks.
4. Confirm delivery and privacy state with /chorus:status.
5. Use /chorus:doctor if any check is not green.
```

Move repository scripts into a clearly labeled legacy section and explain preserved data versus `uninstall --purge`.

- [ ] **Step 5: Run acceptance, docs, and complete isolated suite**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin/test_documentation.py tests/plugin/test_acceptance.py -q`

Run: `HOME=$(mktemp -d) .venv/bin/pytest -q`

Expected: all tests pass; if optional ML/audio integration tests are unavailable, they are explicitly skipped with a documented reason rather than failing collection.

- [ ] **Step 6: Commit documentation and acceptance coverage**

```bash
git add README.md ONBOARDING.md docs/plugin-migration.md tests/plugin/test_documentation.py tests/plugin/test_acceptance.py
git commit -m "docs: make plugin setup the primary chorus workflow"
```

### Task 10: Final Validation and Change-Scope Review

**Files:**
- Modify only files required to resolve validation failures discovered here.

**Interfaces:**
- Verifies every acceptance claim from the approved design and produces the final release evidence.

- [ ] **Step 1: Validate plugin packaging**

Run: `python3 /Users/spark/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py plugins/chorus`

Run when available: `claude plugin validate plugins/chorus --strict`

Expected: valid manifests and plugin structure.

- [ ] **Step 2: Run targeted plugin and regression suites in an isolated home**

Run: `HOME=$(mktemp -d) .venv/bin/pytest tests/plugin tests/test_config.py tests/test_hook_handlers.py tests/test_main.py tts_server/test_server.py tts_server/test_supervisor.py -q`

Expected: all pass with no writes to the real home directory.

- [ ] **Step 3: Run the complete project suite and static checks**

Run: `HOME=$(mktemp -d) .venv/bin/pytest -q`

Run: `.venv/bin/python -m compileall -q hook_voice tts_server plugins/chorus/runtime`

Run: `git diff --check`

Expected: tests pass or optional hardware-only tests skip; compilation and whitespace checks pass.

- [ ] **Step 4: Verify requirements by direct inspection**

Run: `rg -n '/Users/[^/]+' hooks plugins/chorus setup-tts.sh server.sh install.sh uninstall.sh`

Expected: no developer-specific absolute path.

Run: `rg -n 'configured|autoSpeak|usageTracking|external' plugins/chorus/runtime/manifest.json hook_voice/config.py README.md`

Expected: inert defaults and explicit privacy preset documentation agree.

- [ ] **Step 5: Review repository impact before the final commit**

Run GitNexus `detect_changes({scope: "compare", base_ref: "main"})` when the indexed MCP is available. If unavailable, record that limitation and use `git diff --stat main...HEAD`, `git diff --name-status main...HEAD`, and targeted test evidence as the fallback scope review.

Expected: only plugin packaging, runtime boundary/management, compatibility wrappers, tests, and documentation are affected.

- [ ] **Step 6: Commit any validation-only fixes**

```bash
git add <only-the-files-changed-to-fix-validation>
git diff --cached --check
git commit -m "fix: complete chorus plugin validation"
```

- [ ] **Step 7: Record final evidence**

Report manifest validation, test counts, skipped optional integrations, path/privacy scans, changed files, legacy compatibility, and the GitNexus availability gap. Do not claim audible hardware verification unless the audible doctor check was explicitly run on supported hardware.
