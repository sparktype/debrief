#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${CHORUS_RUNTIME_BIN:-$ROOT/plugins/chorus/scripts/chorus-runtime}"
echo "chorus: deprecated 제거 경로를 chorus-runtime으로 마이그레이션합니다. 사용자 데이터는 --purge 없이는 보존됩니다." >&2
exec "$RUNTIME" uninstall "$@"
