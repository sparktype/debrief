#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${CHORUS_RUNTIME_BIN:-$ROOT/plugins/chorus/scripts/chorus-runtime}"
echo "chorus: deprecated 직접 hook 등록 대신 플러그인 설치로 마이그레이션하세요." >&2
echo "Claude와 Codex에서 이 저장소 marketplace의 chorus 플러그인을 설치한 뒤 /chorus:setup을 실행하세요." >&2
exec "$RUNTIME" status
