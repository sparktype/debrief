#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHORUS_HOOK_SOURCE="${CHORUS_HOOK_SOURCE:-claude}" CHORUS_HOOK_EVENT=Stop "$ROOT/plugins/chorus/scripts/chorus-hook" || true
exit 0
