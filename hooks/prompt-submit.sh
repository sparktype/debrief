#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHORUS_HOOK_SOURCE="${CHORUS_HOOK_SOURCE:-claude}" CHORUS_HOOK_EVENT=UserPromptSubmit "$ROOT/plugins/chorus/scripts/chorus-hook" || true
echo '{"continue":true}'
exit 0
