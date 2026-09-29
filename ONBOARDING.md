# debrief onboarding

debrief speaks text prepared by Codex, Claude Code, or Grok. A headless daemon plays the audio. Agents call MCP `speak`. Repair and host wiring can use MCP `install` or the shell install command.

## First installation

1. Build the executable from a checkout of [github.com/sparktype/debrief](https://github.com/sparktype/debrief):

   ```sh
   ./scripts/with-xcode.sh swift build -c release
   ```

   Xcode 27 is required. The Homebrew formula `sparktype/tap/debrief` is not published yet. Tag `v0.0.1` on the tap still builds the previous `chorus` binary.

2. Install the daemon, model, and host wiring (all hosts, or limit with flags):

   ```sh
   debrief install
   # debrief install --claude
   # debrief install --grok --repair
   ```

3. Wait for the pinned Supertonic 3 model download and checksum verification.
4. LaunchAgent starts `debrief daemon` (or run `debrief start`).
5. Confirm MCP server `debrief` is registered for your host(s).
6. **Claude Code:** restart the app so `mcp__debrief__speak` and `mcp__debrief__install` appear. Skills: `~/.claude/skills/debrief-{setup,install,speak}`.
7. **Grok:** run **`/mcps`** so `debrief__speak` and `debrief__install` appear. Skills: `~/.grok/skills/debrief-{setup,install,speak}`. Use `search_tool` / `use_tool` when the host requires it.
8. **Codex:** review start-family hooks in `/hooks`; MCP lives in `~/.codex/config.toml`.
9. At the end of a user-visible turn the agent speaks once via MCP `speak`: what changed, then one next action. Silence only when the turn adds nothing new.

Repair without wiping unrelated host settings:

```sh
debrief install --repair
# or, when MCP already works:
#   Claude: mcp__debrief__install  { "hosts": ["claude"], "repair": true }
#   Grok:   debrief__install       { "hosts": ["grok"], "repair": true }
```

## Daily use

```sh
debrief status
debrief mode [normal|focus|quiet|verbose|night]
debrief mute [on|off|toggle]
debrief companion [on|off|toggle]
debrief doctor
debrief start
debrief stop
```

- **Mode** — `normal` (default); `focus` / `quiet` / `night` suppress `priority=subagent`; quiet/night also lower volume ceilings; `verbose` includes subagent speech
- **Mute** — pause or restore speech
- **도우미 음성** — `debrief companion` turns companion-lane speech on or off (work lane still plays when mute is off)
- **doctor** — findings, including MCP wiring. The first matching recovery is `debrief install --repair` or `debrief start`
- **start / stop** — bootstrap an existing LaunchAgent, or disable and bootout it. Stop keeps the binary and the plist

Agents call MCP `speak`. Hosts spawn `~/.local/bin/debrief mcp` after install. `debrief speak` is not a command.

## Agent rules (all hosts)

- Spoken text is the agent’s job. At the end of each user-visible turn, speak once: **what changed**, then the one **next action** or wait.
- **Silence only** if nothing new and no next action. No file lists or checklists.
- Always pass `voice`, `speed`, and `volume`. Optional: `priority` (`main` default / `subagent`), `lane` (`companion` default / `work`), `emotion` (closed enum; prosody only).
- Companion prefers voice **F1**, speed ~0.93, volume ~0.85. Subagents do not brief the user; if they speak, `priority=subagent` and `lane=work`, one fact.
- Do not put speech JSON or HTML comments in the chat body.
- Mute, mode, companion, and diagnostics: `debrief mute`, `debrief mode`, `debrief companion`, `debrief doctor`.
