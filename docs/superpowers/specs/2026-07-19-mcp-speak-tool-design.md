# Chorus MCP Speak Tool Design

**Date:** 2026-07-19

**Status:** Approved (with product errata below)

**Target:** macOS 14+ Apple Silicon

**Supersedes (speech contract only):** HTML comment speech envelope in
`2026-07-15-swift-single-binary-tts-design.md` §6–8 and related hook Stop
extraction. Menu bar resident process model from
`2026-07-17-menubar-resident-tts-design.md` remains in force.

**Related product choice:** User-selected option 1 — no machine metadata in the
chat body; silence if the agent omits the speak tool (no envelope fallback).

### Product errata (post-approval, 2026-07)

The following are **shipping product truth** and supersede conflicting paragraphs
in the body of this document:

| Topic | Original (2026-07-19) | Current |
| --- | --- | --- |
| MCP tools | `speak` only | `speak` + **`install`** (`hosts`, `repair` default true) |
| Speak `priority` | Main-only / future optional | Optional **`main` \| `subagent`** (default `main`); drives ModePolicy |
| SpeechRequest | Forged `event: .stop` | **`SpeechPriority`** on the request (not hook event names) |
| Grok skills | `chorus-speak` only | **`chorus-setup`**, **`chorus-install`**, **`chorus-speak`** |
| Claude/Codex skills | setup (+ speak later) | **`setup` + `install` + `speak`** |
| TOML `tool_timeout_sec` | 10 | **120** (install may run longer than speak) |
| Diagnostics | last-error + menu line | Also menu **진단** submenu + doctor report copy |
| Modes | envelope-era subagent via Stop | Subagent = MCP `priority=subagent`; volume ceilings for quiet/night |

Canonical user/dev docs: `README.md`, `ONBOARDING.md`, `DEVELOPER.md`, `CLAUDE.md`.

---

## 1. Outcome

Chorus remains a **TTS-only** single Swift executable (`chorus` inside
`Chorus.app`). Agents request speech only through an MCP tool. The chat body
contains natural language only — never `<!-- chorus:speak … -->` or equivalent
JSON side-channels.

The menu bar process continues to own Supertonic, the speech queue, mute/mode,
and the Unix domain socket. A new **thin stdio MCP ingress** (`chorus mcp`) is
spawned by each host; it validates tool arguments, submits the existing UDS
frame, and returns immediately after acknowledgement.

**Hosts:** Codex, Claude Code, and **Grok** (Grok Build / `~/.grok`).

---

## 2. Problem

The prior speech contract forced agents to append an HTML comment envelope to
`last_assistant_message`. Hosts surface that comment in the UI, so users see:

1. a human summary in the body, and
2. a near-duplicate machine line with JSON fields.

The comment is not invisible in practice. That is a structural UX failure of
using the assistant message as a side channel, not a parser bug.

---

## 3. Scope

### In scope

- Replace the speech **ingress** with MCP tool `speak` on server `chorus`
- Subcommand `chorus mcp` (stdio JSON-RPC, tools only)
- Submit speech via existing `UnixSocketClient` / `SpeechRequest` / ResidentService
- Remove HTML envelope authoring from agent context and Stop extraction
- Remove `Stop` / `SubagentStop` hook installation (no speech on those events)
- Keep `SessionStart` / `UserPromptSubmit` / `SubagentStart` on hosts that honor
  context injection; retarget instructions to the MCP tool
- Install MCP server registration for Codex, Claude, and Grok
- Grok-specific install paths: `config.toml` MCP section, skills, hooks file
- Update tests, README, DEVELOPER, CLAUDE, setup skill, fixtures
- Diagnostics: MCP delivery failures → `last-error.json` + menu error line

### Out of scope

- Embedding MCP stdio or HTTP/SSE inside the menu bar process
- Localhost TCP/HTTP MCP transport
- Node, Python, or a second shipped binary
- Chorus-side LLM summarization, STT, transcript parsing, or body heuristics
- Envelope fallback when the agent forgets the tool
- Preferences window, Dock icon, network telemetry
- Changing Supertonic / ONNX / mode policy semantics

---

## 4. Decisions

| Topic | Decision |
| --- | --- |
| Speech side channel | MCP tool only |
| Tool name | `speak` (qualified `chorus__speak` on Grok) |
| Server name | `chorus` |
| Required tool args | `text`, `voice`, `speed`, `volume` (required four); optional `priority` = `main`\|`subagent` (default `main`) |
| Version field | Internal `SpeechEnvelope.v = 1` still set by server; not exposed as MCP arg |
| HTML envelope | Removed from product contract and Stop path |
| Stop / SubagentStop hooks | **Uninstalled** (not no-op stubs) |
| Missing tool call | Silence; agent turn still succeeds |
| MCP process location | Host-spawned `…/chorus mcp`; not in-menu-bar |
| Transport to TTS | Existing user-only Unix domain socket |
| Tool latency | ACK on queue accept only; do not wait for synthesis/playback |
| Runtimes | Swift-only minimal MCP; no Node SDK |
| Hosts | `codex`, `claude`, `grok` |
| CLI install flags | `install [--codex] [--claude] [--grok] [--repair]`; no flags ⇒ all available hosts |
| Voice mismatch | Tool does not receive host `agent_type`; context instructs assigned voice; server validates allowlist/ranges only |

---

## 5. Process Architecture

```text
Codex / Claude Code / Grok
  │ spawn: /Applications/Chorus.app/Contents/MacOS/chorus mcp
  │ stdio MCP (JSON-RPC)
  ▼
chorus mcp
  │ tools/call speak → validate → UnixSocketClient.submit
  │ return { ok: true } after UDS ACK (0x06)
  ▼
~/Library/Caches/Chorus/chorus.sock
  ▼
Chorus.app (menubar) → ResidentService → SpeechQueue → Supertonic → AudioPlayer
```

| Component | Responsibility |
| --- | --- |
| Host | Spawns/stops MCP child; exposes `speak` to the model |
| `chorus mcp` | Protocol + validation + UDS client |
| Menu bar | Sole TTS owner; mute/mode/queue |
| Start-family hooks (Claude/Codex) | Inject “call `speak` with assigned voice” context |
| Grok skill | Durable speak contract (see §8) because SessionStart stdout is ignored |

---

## 6. MCP Surface

### 6.1 Lifecycle

Implement the minimum for host tool use:

- `initialize` / `initialized`
- `tools/list`
- `tools/call`
- `ping` (if requested by host)

No resources, prompts, sampling, or OAuth.

### 6.2 Tool `speak`

**Description (normative gist):** Speak a short one- or two-sentence summary of
the finished work through local Chorus TTS. Call once at the end of a turn when
speech is appropriate. Do not put HTML comments or JSON speech metadata in the
assistant message body.

| Argument | Type | Required | Contract |
| --- | --- | --- | --- |
| `text` | string | yes | Non-empty, ≤ 800 characters; no `-->`; control chars only LF allowed |
| `voice` | string | yes | Allowlist `F1`…`F5`, `M1`…`M5` |
| `speed` | number | yes | Finite, `0.7…2.0` |
| `volume` | number | yes | Finite, `0.0…1.0` |

Server builds:

```text
SpeechEnvelope(v: 1, text, voice, speed, volume)
SpeechRequest(envelope, event: .stop, agentType: nil)
```

`event` is fixed to main-stop priority for queue ordering. Subagent calls use
the same tool; they share main priority unless a later change adds an optional
`priority` field (out of scope here).

### 6.3 Tool results

| Outcome | Result |
| --- | --- |
| UDS ACK | content text or structured `{ "ok": true }`; `isError` false |
| Validation failure | `isError` true; short Korean or English message for the model |
| Socket down / reject | `isError` true; record diagnostics (`component: "mcp"`) |

Do not block the MCP call on audio playback. Match historical hook behavior:
agent completion is independent of whether the user hears speech.

### 6.4 CLI

```text
chorus mcp
```

- Reads JSON-RPC from stdin, writes to stdout; logs only to stderr if needed
- `CHORUS_HOME` honored for tests
- Removed user CLI surface stays removed (`speak`, `mute`, `mode`, …)

---

## 7. Hook Changes (Claude / Codex)

| Event | Action |
| --- | --- |
| `SessionStart` | Inject speak-tool contract + assigned voice/speed for main agent |
| `UserPromptSubmit` | Compact reminder: call `speak` once; no body metadata |
| `SubagentStart` | Role voice assignment + speak-tool contract |
| `Stop` | **Do not install** |
| `SubagentStop` | **Do not install** |

`VoiceCatalog.context(for:)` is rewritten to MCP instructions. Example gist:

```text
When you finish this turn, call the Chorus MCP tool `speak` once with a one- or
two-sentence spoken summary. Required args: text, voice, speed, volume.
Use voice F1 (연아), speed near 0.93, volume near 0.85 unless content needs
another speed in 0.7–2.0. Do not append HTML comments or JSON speech metadata
to the assistant message.
```

`HookEngine` Stop branches that parse envelopes are deleted. Start-family
branches remain.

`EmbeddedTemplates.hookEvents` becomes the three start events only. Repair and
uninstall remove previously owned Stop entries when digests match.

---

## 8. Grok Host Support

### 8.1 Why Grok is different

| Concern | Claude / Codex | Grok |
| --- | --- | --- |
| MCP config | JSON settings (`mcpServers`) | TOML `~/.grok/config.toml` `[mcp_servers.<name>]` |
| Hook files | Nested in settings / hooks.json | `~/.grok/hooks/*.json` (merged) |
| SessionStart stdout | `additionalContext` (Claude) | **Ignored** (passive hooks: exit 0 only) |
| Skills | `~/.claude/skills`, `~/.agents/skills` | `~/.grok/skills/<name>/SKILL.md` |
| Tool naming | server tools as configured | `server__tool` (e.g. `chorus__speak`) via `search_tool` / `use_tool` |

Therefore Grok cannot rely on SessionStart hook stdout for the speech contract.

### 8.2 Grok install artifacts

1. **MCP (required)** — merge into `~/.grok/config.toml` (user scope):

   ```toml
   [mcp_servers.chorus]
   command = "/Applications/Chorus.app/Contents/MacOS/chorus"
   args = ["mcp"]
   enabled = true
   startup_timeout_sec = 15
   tool_timeout_sec = 10
   ```

   Owned section is tracked by digest of the normalized TOML fragment (or full
   table body). Unrelated `[mcp_servers.*]` tables are preserved. If the user
   modified the owned table (digest mismatch), repair preserves it and reports
   `preserved modified file` like skills today.

2. **Skill (required for contract)** — `~/.grok/skills/chorus-speak/SKILL.md`

   - `name: chorus-speak`
   - `description:` must mention finishing turns / spoken summary / Chorus TTS
     so Grok can activate it when relevant
   - Body: same speak contract as hook context; tool name `chorus__speak` or
     “server `chorus` tool `speak`”; assigned default main voice F1

3. **Hooks (optional, limited)** — `~/.grok/hooks/chorus.json`

   - May install `SessionStart` / `UserPromptSubmit` / `SubagentStart` **only if**
     useful for side effects later; **must not depend on stdout context**
   - v1 recommendation: **skip Grok command hooks** for speech context; skill +
     MCP tool description carry the contract. Revisit if Grok adds context
     injection for SessionStart.

4. **Setup skill** — extend shared setup text to mention Grok: enable MCP,
   `/mcps` refresh, folder trust not required for user-scope `~/.grok` MCP.

### 8.3 HostSource

```swift
public enum HostSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case grok
}
```

`HostInstaller` gains TOML merge helpers for Grok MCP and skill path
`~/.grok/skills/…`. Diagnostics `hostSettingsReadable` includes Grok config
readability (`~/.grok/config.toml`).

### 8.4 CLI

```text
chorus install --grok
chorus uninstall --grok
chorus install              # all hosts Chorus can configure
```

`HookAdapter` / `hook --source grok` is only needed if Grok hooks are installed.
If v1 skips Grok hooks, `hook --source` accepts `codex|claude` only until hooks
return.

---

## 9. Codex and Claude MCP Install

Mirror Grok’s MCP registration in each host’s native settings shape:

| Host | Location | Shape |
| --- | --- | --- |
| Claude | `~/.claude/settings.json` (or documented mcp path used by install today) | `mcpServers.chorus = { command, args }` |
| Codex | documented Codex MCP / config path used by install | same logical entry |
| Grok | `~/.grok/config.toml` | `[mcp_servers.chorus]` |

Exact Claude/Codex file keys must match current host docs at implementation
time; tests pin the chosen shape. Owned digests prevent clobbering user edits.

Legacy: if an old Chorus-owned envelope-era MCP or node entry matches a known
digest, uninstall/repair may remove it. Unrelated MCP servers stay.

---

## 10. Removed Surface

| Remove | Notes |
| --- | --- |
| Agent HTML envelope contract | Context, README, fixtures |
| `SpeechEnvelopeParser` product use | Delete or keep only if unused — prefer delete |
| Stop / SubagentStop hooks | Uninstall + stop installing |
| “No MCP” product rule | Replace with “stdio MCP ingress only; no HTTP/Node MCP runtime” |

**Keep:** internal `SpeechEnvelope` validation model, UDS frame, menu bar,
modes, mute, model install, `DirectSpeechCommand`-style submit path for the MCP
adapter.

---

## 11. Errors and Diagnostics

| Failure | Behavior |
| --- | --- |
| Invalid tool args | MCP `isError`; no UDS write |
| Menu bar / socket down | MCP `isError`; `last-error.json` message suitable for menu |
| Agent never calls tool | Silence; no error (by design) |
| Partial double call | Existing short-window dedupe on envelope digest still applies |

User-facing Korean strings remain polite (경어체) where shown in the menu.

---

## 12. Security and Privacy

- Socket remains user-only (`0700` dir, `0600` sock)
- MCP child is local stdio; no network listener
- Do not persist spoken text or audio beyond in-memory queue
- Installer never overwrites user-modified owned files; preserve + report

---

## 13. Testing

### Unit / core

- MCP initialize, tools/list, tools/call success path
- Validation matrix for `speak` args
- UDS submit integration with test socket / fake ResidentService
- `HostSource.grok` install merge: add/remove/preserve foreign MCP tables
- TOML fragment merge without destroying unrelated keys
- Hook event set: only three start events for Claude/Codex templates
- `VoiceCatalog.context` contains `speak` and does **not** contain `chorus:speak`

### Integration / smoke

- Release binary `chorus mcp` handshakes under a small MCP client fixture
- Claude/Codex/Grok install dry-run under temp `HOME`
- Manual: body has no envelope; one `speak` call produces audio
- Manual Grok: `grok mcp doctor chorus` (or list) shows server; tool speak works

### Regression

- Menu bar mute/mode/queue tests unchanged in intent
- No Python/Node dependencies introduced

---

## 14. Documentation Updates

- `README.md` — speech contract via MCP; hosts include Grok; remove HTML example
- `DEVELOPER.md` — process diagram; MCP ingress; Grok paths
- `CLAUDE.md` / `ONBOARDING.md` — install flags; agent instructions
- `EmbeddedTemplates` setup skill — MCP + Grok notes
- Mark envelope sections of 2026-07-15 design as superseded by this document

---

## 15. Implementation Plan Outline

1. **MCP server core** — `chorus mcp`, tool `speak`, UDS submit, unit tests  
2. **HostInstaller MCP** — Claude + Codex JSON merge; Grok TOML merge; digests  
3. **Grok skill** — `chorus-speak` template; install/uninstall  
4. **Hook cutover** — rewrite context; drop Stop/SubagentStop; engine cleanup  
5. **Delete envelope parser product path** and fixture HTML comments  
6. **Docs** + setup skill  
7. **Release verification** — `./scripts/with-xcode.sh swift test` + release build + host smoke  

TDD: failing tests for MCP speak and Grok install before production code.

---

## 16. Risks

| Risk | Mitigation |
| --- | --- |
| Agents forget `speak` | Strong context/skill/tool description; accept silence (product choice) |
| Grok requires `search_tool` before `use_tool` | Tool description + skill teach qualified name `chorus__speak` |
| TOML merge bugs | Round-trip tests; preserve unknown sections; prefer surgical table replace by ownership |
| Host MCP schema drift | Abstract “McpRegistration” + per-host serializers; pin fixtures |
| Scope creep into summarization | Explicit out-of-scope; tool requires agent-authored `text` |

---

## 17. Success Criteria

1. Assistant-visible messages contain no Chorus speech HTML/JSON metadata when
   agents follow the contract.
2. A valid `speak` tool call enqueues audio through the menu bar resident.
3. `install` configures Codex, Claude, and Grok MCP (and Claude/Codex start hooks
   + Grok skill) idempotently.
4. `uninstall` removes only Chorus-owned MCP/hooks/skills.
5. Full Swift test suite and release build pass under Xcode 27 beta.
6. Product remains TTS-only with a single shipped binary and no Node/Python
   runtime.

---

## 18. Open Items Resolved in This Draft

| Item | Resolution |
| --- | --- |
| Stop hooks | Fully remove from install set |
| Tool arity | All four user fields required (`text`/`voice`/`speed`/`volume`) |
| Tool name | `speak` |
| Envelope fallback | None |
| Grok | First-class host via MCP + skill |
| MCP inside menubar | Rejected; stdio child + UDS only |
