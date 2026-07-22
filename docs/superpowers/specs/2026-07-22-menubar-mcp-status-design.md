# Menu Bar MCP Host Status Design

**Date:** 2026-07-22  
**Status:** Implemented  
**Target:** macOS 14+ Apple Silicon, Chorus 2.x  
**Depends on:** MCP speak + install (`2026-07-19-mcp-speak-tool-design.md`), menubar resident (`2026-07-17-menubar-resident-tts-design.md`)

---

## 1. Outcome

Users can open the Chorus menu bar and **see whether Claude, Codex, and Grok have `chorus` MCP wired correctly** (status lines with emoji), and can **repair problem hosts** without leaving the menu. The wider menubar also uses **leading Unicode emoji** on action titles so states and controls scan faster.

Agents and chat hosts still own tool discovery; Chorus only reports **on-disk host configuration** and re-runs the existing install/repair path.

---

## 2. Problem

MCP is the primary speech path (`speak` / `install`). Wiring lives in host config files:

| Host | Config |
|------|--------|
| Claude | `~/.claude/settings.json` → `mcpServers.chorus` |
| Codex | `~/.codex/config.toml` → `[mcp_servers.chorus]` |
| Grok | `~/.grok/config.toml` → `[mcp_servers.chorus]` |

Today the menu bar shows service / mute / companion / mode and a generic **진단** list. Diagnostics check host file readability, not whether **chorus MCP is registered** or whether the **command path matches the installed app**. Users discover broken MCP only when a host fails to list tools.

---

## 3. Product boundary

### In scope

- Per-host MCP registration probe (present / absent / unreadable / path mismatch)
- Menu **MCP** submenu with one line per host (Korean, 경어체)
- **Menu emoji (이모티콘)** on MCP submenu and the rest of the menubar action titles for scannability
- Doctor findings for problem states (copyable with 진단 요약 복사)
- **문제 에이전트 복구** menu action → install/repair for agents that fail the probe
- Unit/integration tests for probe + status + doctor codes

### Out of scope

- Live MCP process / stdio connection presence (host-spawned; not a Chorus daemon)
- Last `speak` / `install` activity log
- Repair that only patches config without `RuntimeInstaller` (reuse install pipeline)
- New CLI surface for mute/mode (menu remains the control plane)
- Custom SF Symbol assets or animated menu icons (Unicode emoji only)

---

## 4. Status model

```text
HostMcpState =
  | ok            — chorus MCP registered; command path matches expected binary
  | missing       — host config file exists; no chorus MCP entry
  | absent        — host config file does not exist (host unused)
  | unreadable    — config exists but cannot be read/parsed as expected
  | stalePath     — chorus MCP present; command ≠ expected installed executable
```

| State | Doctor problem? | Menu tone | Leading emoji |
|-------|-----------------|-----------|---------------|
| `ok` | No | 등록됨 | ✅ |
| `absent` | No | 설정 없음 | ⚪ |
| `missing` | Yes | 미등록 | ⚠️ |
| `unreadable` | Yes | 설정 읽기 실패 | ❌ |
| `stalePath` | Yes | 경로 불일치 | 🔄 |

**Expected executable:** the installed application binary used for host registration (`ChorusPaths` application executable, same target `HostInstaller` / `EmbeddedTemplates.mcpRegistration` write). Compare resolved paths when possible.

**Codex note:** MCP must be read from `config.toml`, not `hooks.json` (legacy JSON MCP is retired).

---

## 5. Probe rules (per host)

### 5.1 Claude (JSON)

1. If `~/.claude/settings.json` missing → `absent`
2. If unreadable or not a JSON object → `unreadable`
3. If `mcpServers.chorus` missing → `missing`
4. Else read `command` (string); if equal to expected executable path → `ok`, else `stalePath`

### 5.2 Codex / Grok (TOML)

1. If config path missing → `absent`
2. If not UTF-8 readable → `unreadable`
3. If no `[mcp_servers.chorus]` table (and no owned marker block containing it) → `missing`
4. Else extract `command` from the table (owned fragment preferred; else whole-file table). Path match → `ok`, else `stalePath`

Owned markers (`# BEGIN chorus-mcp` … `# END chorus-mcp`) remain the install ownership signal; probe does not require markers for `ok` if the table exists and path matches (user or host may have written an equivalent table).

---

## 6. Menu UX

### 6.1 MCP submenu (with emoji)

```text
[헤더 요약]
[❌ 오류: …]                      # existing error row, emoji prefix when present
🔌 MCP | 🔌 MCP (문제 있음)  ▸
    ✅ Claude: 등록됨
    ⚠️ Codex: 미등록
    🔄 Grok: 경로 불일치
    ────────
    🔧 문제 에이전트 복구         # enabled only if any problem agent
🩺 진단 | 🩺 진단 (문제 있음)  ▸  # existing; gains mcp.* findings
…
```

- Agent lines: disabled (display only). Format:  
  `{stateEmoji} {AgentDisplayName}: {KoreanState}`  
  e.g. `✅ Claude: 등록됨`, `⚠️ Codex: 미등록`, `⚪ Grok: 설정 없음`
- **문제 에이전트 복구**:
  - Title: `🔧 문제 에이전트 복구`
  - Disabled when every agent is `ok` or `absent`.
  - Enabled when any agent is `missing` / `unreadable` / `stalePath`.
  - Runs repair only for **problem** agents (not `absent` / `ok`).
- On success: clear stale install error when appropriate, refresh status.
- On failure: surface via existing `lastError` + `Diagnostics.recordError` (`component: "mcp"` or `"app"` consistent with install tool).
- No second “전체 재배선” item in v1 (YAGNI).

Root title: `🔌 MCP` when healthy; `🔌 MCP (문제 있음)` iff any host has `isProblem == true`.

### 6.2 Menubar emoji map (full menu)

Unicode emoji **prefix** on menu titles (space after emoji). Status-item badge remains custom drawing.  
Doctor **finding body text** and pasteboard report stay code-oriented (no required emoji there) so logs stay greppable; only **menu chrome** uses emoji.

### 6.3 Status-item badge width

Keep the existing voice/transport badge drawing, but **narrow the image slightly** so the menu-bar slot is less wide:

| Constant | Previous | Target |
|----------|----------|--------|
| `MenuBarBadgeDrawing.badgeSize` | 28×16 → 22×16 | **25×16** (tuned for legibility) |
| Voice label font | monospaced 10 → 9 bold | monospaced **9.5** bold |
| App silhouette template side | 18 | **16** (standard menubar glyph size) |

Height stays 16 (menu-bar convention). No change to `NSStatusItem.variableLength` policy—the button sizes to the image.

| Menu item | Emoji | Title examples |
|-----------|-------|----------------|
| MCP root | 🔌 | `🔌 MCP` / `🔌 MCP (문제 있음)` |
| Host line | per state (§4 table) | `✅ Claude: 등록됨` |
| MCP repair | 🔧 | `🔧 문제 에이전트 복구` |
| Error row | ❌ | `❌ 오류: …` |
| Doctor root | 🩺 | `🩺 진단` / `🩺 진단 (문제 있음)` |
| Doctor OK leaf | ✅ | `✅ 문제 없음` |
| Doctor problem leaf | ⚠️ | optional prefix on problem lines in submenu only |
| Copy doctor | 📋 | `📋 진단 요약 복사` |
| Mute | 🔇 / 🔊 | `🔇 음소거` / `🔊 음소거 해제` |
| Companion | 🗣️ | `🗣️ 도우미 음성 끄기` / `🗣️ 도우미 음성 켜기` |
| Mode root | 🎚️ | `🎚️ 모드` |
| Mode items | (none or ·) | keep `normal — 기본` text; optional leading `•` only if needed for alignment—**no per-mode emoji required** |
| Service start | ▶️ | `▶️ 서비스 시작` |
| Service stop | ⏹ | `⏹ 서비스 중지` |
| Quit | ⏻ | `⏻ Chorus 종료` |

**Rules**

- One leading emoji + space + Korean/English title; do not stack multiple emoji.
- Prefer emoji that render in default macOS menu fonts (avoid obscure ZWJ sequences).
- Summary **header** line stays text-only (already dense: service · mute · companion · mode · voice).
- Tests assert substring of Korean labels and, where useful, the fixed emoji constant (e.g. host line starts with `✅`).

---

## 7. Architecture

```text
Menu open / voice poll refresh
  → Diagnostics.hostMcpStatuses()   // pure, home-scoped
  → MenuBarStatus.mcpLines + hasMcpProblems
  → MenuBarApp rebuild MCP submenu

doctor()
  → for each problem HostMcpStatus
       DiagnosticFinding(code: "mcp.{host}.{state}", ok: false, recovery: …)

문제 에이전트 복구
  → MenuBarController.repairProblemMcpHosts()
       → RuntimeInstaller.install(hosts: problemHosts, repair: true)
       → refresh()
```

| Type / API | Responsibility |
|------------|----------------|
| `HostMcpState` | Closed enum |
| `HostMcpStatus` | `host`, `state`, `menuLine` (includes state emoji), `isProblem`, optional recovery string |
| Menu title helpers | Small pure functions or static maps for emoji prefixes (testable without AppKit) |
| `Diagnostics.hostMcpStatuses()` | Probe all `HostSource.allCases` |
| `Diagnostics.doctor()` | Append `mcp.*` findings for problems |
| `MenuBarStatus` | Carry `mcpLines: [String]`, `hasMcpProblems: Bool` |
| `MenuBarController` | Fill status on refresh; enqueue repair |

Prefer a small dedicated probe helper (file-private or `HostMcpProbe`) if `Diagnostics.swift` would become hard to follow; public surface stays on `Diagnostics` for menu/doctor callers.

**Recovery copy (examples):**

- `missing` → `chorus install --{host} --repair` (or menu 복구)
- `stalePath` → same
- `unreadable` → host-aware repair of JSON/TOML then re-run install (align with existing `host.*.invalid_*` wording)

Avoid duplicate doctor noise: if a host is `unreadable`, emit **one** finding. Prefer `mcp.{host}.unreadable` when the failure is discovered via the MCP probe path; keep existing `host.*.invalid_*` only if still produced by the readability loop and not redundant. Implementation should not list the same unreadable host twice—collapse to a single code (`mcp.*.unreadable` is enough when MCP status ships).

---

## 8. Error handling

| Case | Behavior |
|------|----------|
| Probe I/O failure | Treat host as `unreadable`; never crash menubar |
| Repair in flight | Existing `enqueue` serializes with mute/mode/start |
| Repair partial host set | Installer already host-scoped; report first failure message |
| User never uses a host | `absent` — not a problem; not repaired |

---

## 9. Testing

1. **Probe unit tests** (temp `CHORUS_HOME` / home URL):
   - each state for Claude JSON and one TOML host
   - path match vs mismatch
   - Codex ignores hooks.json for MCP presence
2. **doctor**: problem hosts appear as `mcp.*`; `absent`/`ok` do not
3. **MenuBarStatus**: `hasMcpProblems`, `mcpLines` count/content; each line includes the §4 state emoji
4. **Menu title map**: mute/companion/doctor/MCP root strings match the emoji table (unit-test pure helpers)
5. **Repair** (integration or controller with mock installer if already injectable): problem hosts passed with `repair: true`; ok/absent omitted

TDD: failing tests first.

---

## 10. Docs / product strings

- User-facing menu strings: Korean 경어체.
- Optional one-line ONBOARDING / DEVELOPER mention: “메뉴바 → MCP에서 에이전트 배선 확인·복구”.
- No change to MCP tool schemas.

---

## 11. Implementation plan (PR-sized)

1. `HostMcpState` / `HostMcpStatus` + probe + tests (emoji in `menuLine`)  
2. Wire `doctor()` + `MenuBarStatus` / controller refresh  
3. Menu submenu UI + full menubar emoji title map  
4. Status-item badge width (`badgeSize` 25×16, silhouette 16)  
5. Repair action via installer  
6. Light doc touch + full `swift test`

---

## 12. Non-goals reminder

Chorus does **not** claim the agent host has reloaded tools (`/mcps`, Claude restart). After successful repair, menu shows on-disk wiring OK; agent-side refresh remains the user’s step. Menu recovery text may note: “에이전트에서 MCP 목록을 새로고침하세요.”
