# Chorus onboarding

Chorus speaks text prepared by Codex, Claude Code, or Grok through **Chorus.app** (menu bar) via the MCP tool `speak`. Repair and host wiring can use MCP `install` or the shell install command.

## First installation

1. Install the CLI with Homebrew:

   ```sh
   brew install sparktype/tap/chorus
   ```

   From a source checkout instead: `./scripts/with-xcode.sh swift build -c release` (Xcode 27), then use `.build/release/chorus` in the next step.

2. Install the app, model, and host wiring (all hosts, or limit with flags):

   ```sh
   chorus install
   # chorus install --claude
   # chorus install --grok --repair
   ```

3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. Open **Chorus** from Applications (or wait for LaunchAgent at login).
5. Confirm MCP server `chorus` is registered for your host(s).
6. **Claude Code:** restart the app so `mcp__chorus__speak` and `mcp__chorus__install` appear. Skills: `~/.claude/skills/chorus-{setup,install,speak}`.
7. **Grok:** run **`/mcps`** so `chorus__speak` and `chorus__install` appear. Skills: `~/.grok/skills/chorus-{setup,install,speak}`. Use `search_tool` / `use_tool` when the host requires it.
8. **Codex:** review start-family hooks in `/hooks`; MCP lives in `~/.codex/config.toml`.
9. At the end of a user-visible turn the agent speaks once via MCP `speak`: what changed, then one next action. Silence only when the turn adds nothing new.

Repair without wiping unrelated host settings:

```sh
chorus install --repair
# or, when MCP already works:
#   Claude: mcp__chorus__install  { "hosts": ["claude"], "repair": true }
#   Grok:   chorus__install       { "hosts": ["grok"], "repair": true }
```

## Daily use

Control everything from the **menu bar**:

- **Mode** — `normal` (default); `focus` / `quiet` / `night` suppress `priority=subagent`; quiet/night also lower volume ceilings; `verbose` includes subagent speech
- **Mute** — pause or restore speech
- **도우미 음성** — companion-lane on/off (work lane still allowed when on mute off)
- **MCP** — Claude / Codex / Grok wiring status; **문제 에이전트 복구** re-runs install repair for broken agents
- **진단** — doctor findings (includes MCP problems); copy full report
- **Start / Stop service** — TTS service only
- **Chorus 종료** — quit (disables auto-start until reinstall)

There is no user CLI for mute/mode/status/speak. Agents call MCP `speak`; hosts spawn `…/chorus mcp` after install.

## Agent rules (all hosts)

- Spoken text is the agent’s job. At the end of each user-visible turn, speak once: **what changed**, then the one **next action** or wait.
- **Silence only** if nothing new and no next action. No file lists or checklists.
- Always pass `voice`, `speed`, and `volume`. Optional: `priority` (`main` default / `subagent`), `lane` (`companion` default / `work`), `emotion` (closed enum; prosody only).
- Companion prefers voice **F1**, speed ~0.93, volume ~0.85. Subagents do not brief the user; if they speak, `priority=subagent` and `lane=work`, one fact.
- Do not put speech JSON or HTML comments in the chat body.
- Mute / mode / **도우미 음성** / diagnostics: menu bar only.
