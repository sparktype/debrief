#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${CHORUS_RUNTIME_BIN:-$ROOT/plugins/chorus/scripts/chorus-runtime}"
echo "chorus: deprecated 저장소 설치 경로를 플러그인 런타임으로 마이그레이션합니다." >&2
"$ROOT/scripts/build-plugin-runtime.sh"
exec "$RUNTIME" install "${CHORUS_VERSION:-1.0.0}"
