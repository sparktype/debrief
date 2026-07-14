#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${CHORUS_RUNTIME_BIN:-$ROOT/plugins/chorus/scripts/chorus-runtime}"
COMMAND="${1:-status}"
shift || true
echo "chorus: deprecated server.sh 명령을 chorus-runtime으로 마이그레이션합니다." >&2
exec "$RUNTIME" "$COMMAND" "$@"
