---
name: debrief-install
description: 'Install or repair the debrief daemon, MCP tools (speak/install), and Claude/Codex/Grok host wiring. Prefer MCP install tool when available.'
---

# debrief-install

## Preferred (when MCP already works)

Call MCP tool `install` on server `debrief`:

- Claude: `mcp__debrief__install`
- Grok: `debrief__install` (`search_tool` / `use_tool`)
- Codex: tool `install` on server `debrief`

Arguments:

- `hosts`: optional array — `"claude"`, `"codex"`, `"grok"` (omit = all)
- `repair`: boolean, default **true**

Examples:
- Codex only: `{ "hosts": ["codex"], "repair": true }`
- Claude only: `{ "hosts": ["claude"], "repair": true }`
- Grok only: `{ "hosts": ["grok"], "repair": true }`

Select the current host explicitly; omit `hosts` only when all hosts are intended.

Then refresh the host (Codex/Claude: restart; Grok: `/mcps`). In Codex, review debrief in `/hooks` (App: Review hooks); never write trust hashes on the user's behalf.

## Shell (first install or MCP timeout)

```bash
debrief install --codex --repair
# other hosts: --claude | --grok; omit flags only for all hosts
```

Or use the installed binary: `'debrief' install --codex --repair`. Keep the same `CODEX_HOME` for install, doctor and uninstall; default is `~/.codex`. Shared skills remain in `~/.agents/skills`.

## After install

1. Host MCP registration for `debrief`
2. Skills: debrief-install, debrief-speak
3. Tools: speak + install (Grok: `debrief__speak` / `debrief__install`)
4. Check with `debrief doctor`